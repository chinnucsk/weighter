-module(weighter).

-export([start/0]).
-export([setup_user/4]).
-export([use_weight/3, weight_for_user/2]).
-export([receive_weight/4, receive_weight/5]).
-export([total_rank/2]).

% this is: calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}).
-define(ERLANG_GS_EPOCH_OFFSET, 62167219200).

%%%--------------------------------------------------------------------
%%% starting
%%%--------------------------------------------------------------------
start() ->
  application:start(weighter).

%%%--------------------------------------------------------------------
%%% Weight Allocation
%%%--------------------------------------------------------------------
setup_user(Uid, _, _, Uid) ->
  cant_inherit_from_self;
setup_user(Uid, Space, AgeFromSiteEpoch, InheritFromUid) when
    is_integer(AgeFromSiteEpoch) ->
  case er:exists(redis_weighter, genkey(Space, Uid)) of
     true -> user_already_setup;
    false -> {Rank, Growth, Decay} = space_rate(Space, AgeFromSiteEpoch),
             UsableRank = iof(trunc(Rank)),
             base_rank(Space, Uid, UsableRank),
             add_to_total_rank(Space, Uid, UsableRank),
             case Growth of
               false -> ok;
                   _ -> growth_rate(Space, Uid, Growth)
             end,
             case Decay of
               false -> ok;
                   _ -> decay_rate(Space, Uid, Decay)
             end,
             user_current_weight(Space, Uid, UsableRank),
             case InheritFromUid of
               none -> ok;
                  _ -> apply_inheritance(Space, InheritFromUid, Uid)
             end,
             trunc(Rank)
  end.

space_rate(vampire, AgeInSeconds) ->
  Rank = math:sqrt(math:pow(AgeInSeconds/1000, -0.6) * 5000000000) * 10,
  GrowthRatePerSecond = 0.02 / (86400 * 20), % 20 day months
  DecayRatePerSecond = -0.09 / (86400 * 20),
  {Rank, iof(GrowthRatePerSecond), iof(DecayRatePerSecond)};
space_rate(comments, _) ->
  {0, false, false};
space_rate(posts, _) ->
  {0, false, false};
space_rate(karma, _) ->
  {0, false, false};
space_rate(mana, _) ->
  {50, false, false}.

apply_inheritance(Space, FromUid, ToUid) ->
  with_lock(FromUid, Space, fun(_) ->
    Kids = case er:scard(redis_weighter, key_children(Space, FromUid)) of
              nil -> 0;
             <<>> -> 0;
               Ns -> Ns
           end,
    Dosage = trunc(base_rank(Space, FromUid) / (Kids + 2)),
    if
      Dosage < 0 -> nope;
            true -> give(Space, Dosage, FromUid, ToUid)
    end
  end).

give(Space, Dosage, FromUid, ToUid) ->
  dosage_from_parent(Space, ToUid, Dosage),
  parent(Space, ToUid, FromUid),
  er:sadd(redis_weighter, key_children(Space, FromUid), ToUid),
  add_to_total_rank(Space, ToUid, Dosage),
  add_to_user_current_weight(Space, ToUid, Dosage).

%%%--------------------------------------------------------------------
%%% Weight Usage
%%%--------------------------------------------------------------------
calc_use(UseWeight, AvailableWeight) when UseWeight < AvailableWeight ->
  {AvailableWeight - UseWeight, UseWeight};
calc_use(UseWeight, AvailableWeight) when UseWeight >= AvailableWeight ->
  {0, AvailableWeight}.

use_weight(Uid, Space, UseWeight) when is_binary(UseWeight) ->
  use_weight(Uid, Space, list_to_integer(binary_to_list(UseWeight)));
use_weight(Uid, Space, UseWeight) when is_integer(UseWeight) ->
  with_lock(Uid, Space, fun(AvailableWeight) ->
    {NewWeight, UsedWeight} = calc_use(UseWeight, AvailableWeight),
    user_current_weight(Space, Uid, NewWeight),
    UsedWeight
  end).

receive_weight(FromUid, ToUid, Space, Amount) ->
  receive_weight(FromUid, ToUid, Space, Amount, []).

% You can't give/receive to/from yourself.
receive_weight(Uid, Uid, _, _, _) -> 0;
receive_weight(FromUid, ToUid, Space, Amount, ExtraSpaces) when
    is_binary(Amount) ->
  receive_weight(FromUid, ToUid, Space,
    list_to_integer(binary_to_list(Amount)), ExtraSpaces);
receive_weight(FromUid, ToUid, Space, Amount, ExtraSpaces) when
    is_integer(Amount) andalso Amount > 0 ->
  with_lock(FromUid, Space, fun(FromWeight) ->
    with_lock(ToUid, Space, fun(ToWeight) ->
      {_NewFromWeight, UsedWeight} = calc_use(Amount, FromWeight),
      user_current_weight(Space, FromUid, FromWeight - UsedWeight),
      user_current_weight(Space, ToUid, ToWeight + UsedWeight),
      % extra non-pair-bound weight additions:
      [add_to_user_current_weight(S, ToUid, UsedWeight) || S <- ExtraSpaces],
      UsedWeight
    end)
  end).

%%%--------------------------------------------------------------------
%%% Weight Backending
%%%--------------------------------------------------------------------
weight_for_user(Uid, Space) ->
  case user_current_weight(Space, Uid) of
     nil -> 0;
    <<>> -> 0;
       W -> list_to_integer(binary_to_list(W))
  end.

%%%--------------------------------------------------------------------
%%% Helpers
%%%--------------------------------------------------------------------
with_lock(Uid, Space, DoFun) ->
  % this could be a bunch of fancy automatic redis scripting stuff, but not yet.
  case lock(Space, Uid) of
     true -> try  % this returns the result of DoFun/1, not unlock/1
               CurrentWeight = weight_for_user(Uid, Space),
               DoFun(CurrentWeight)
             after
               unlock(Space, Uid)
             end;
    false -> timer:sleep(800),
             with_lock(Uid, Space, DoFun) % yay infinite loops!
  end.

lock(Space, Uid) ->
  Key = key_locker(Space, Uid),
  er:setnx(redis_weighter, Key, term_to_binary(now())),
  er:expire(redis_weighter, Key, 5).  % auto delete after 5 seconds

unlock(Space, Uid) ->
  er:del(redis_weighter, key_locker(Space, Uid)).

%%%--------------------------------------------------------------------
%%% Keys
%%%--------------------------------------------------------------------
% Key model is:
%  weight - the usable weight for the user.  added/subtracted to
%  base_rank - the user's signup position.
%  total_rank - the user's signup position with the parent addition
%  dosage - part of total_rank that came from parent
%  children -- set of uids that are children of the parent uid
%  parent - the parent of this uid
%  decay -- decay rate for this user (in units of 20 days = 1 month)
%  growth -- growth rate for this user (in units of 20 days = 1 month)

genkey(Space, Uid) ->
  eru:er_key(weighter, space, Space, Uid).

genkey(Space, What, Uid) ->
  eru:er_key(weighter, space, Space, What, Uid).

hset(Space, Uid, Field, What) ->
  er:hset(redis_weighter, genkey(Space, Uid), Field, What).

hget(Space, Uid, Field) ->
  er:hget(redis_weighter, genkey(Space, Uid), Field).

key_locker(Space, Uid) ->
  genkey(Space, Uid, templock).

user_current_weight(Space, Uid, Weight) ->
  hset(Space, Uid, weight, Weight).
user_current_weight(Space, Uid) ->
  hget(Space, Uid, weight).

add_to_user_current_weight(Space, Uid, Dosage) ->
  er:hincrby(redis_weighter, genkey(Space, Uid), weight, Dosage).

base_rank(Space, Uid, Rank) ->
  hset(Space, Uid, base_rank, Rank).

base_rank(Space, Uid) ->
  case hget(Space, Uid, base_rank) of
    nil -> 0;
      N -> list_to_integer(binary_to_list(N))
  end.

add_to_total_rank(Space, Uid, Rank) ->
  er:hincrby(redis_weighter, genkey(Space, Uid), total_rank, Rank).

total_rank(Space, Uid) ->
  hget(Space, Uid, total_rank).

growth_rate(Space, Uid, Rate) ->
  hset(Space, Uid, growth, Rate).

decay_rate(Space, Uid, Rate) ->
  hset(Space, Uid, decay, Rate).

key_children(Space, Uid) ->
  genkey(Space, children, Uid).

dosage_from_parent(Space, Uid, Dosage) ->
  hset(Space, Uid, dosage, Dosage).

parent(Space, Uid, Parent) ->
  hset(Space, Uid, parent, Parent).

iof(Bad) ->
  iolist_to_binary(io_lib:format("~w", [Bad])).
