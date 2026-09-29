%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2026 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

%% Simulates a queue that is deleted after routing and before delivery: routing
%% keeps returning the deleted queue's target. rabbitmq/rabbitmq-server#17645.
-module(stale_target_utils).

-export([create/3,
         route/4,
         stop_routing/2,
         get_targets/1]).

-define(KEY, {?MODULE, stale_target}).
-define(TIMEOUT, 30_000).

%% Declares, unless it exists, and deletes the classic queue `QueueName' in
%% vhost `/' and returns its target once the queue process has exited.
create(Config, Node, QueueName) ->
    QName = rabbit_misc:r(<<"/">>, queue, QueueName),
    {_NewOrExisting, Q} = rpc(Config, Node, rabbit_amqqueue, declare,
                              [QName, true, false, [], none, <<"acting-user">>]),
    [Target] = rpc(Config, Node, rabbit_db_queue, get_targets, [[QName]]),
    QPid = rpc(Config, Node, amqqueue, get_pid, [Target]),
    MRef = erlang:monitor(process, QPid),
    {ok, _} = rpc(Config, Node, rabbit_amqqueue, delete,
                  [Q, false, false, <<"acting-user">>]),
    receive {'DOWN', MRef, process, QPid, _} -> Target
    after ?TIMEOUT -> ct:fail(queue_process_still_alive)
    end.

%% Makes `rabbit_db_queue:get_targets/1' on `Node' return `Target' whenever the
%% routed names include its name or one of `TriggerQueueNames'. A live queue
%% with the same name as `Target' is left out.
route(Config, Node, Target, TriggerQueueNames) ->
    Triggers = [rabbit_misc:r(<<"/">>, queue, N) || N <- TriggerQueueNames],
    ok = rpc(Config, Node, persistent_term, put, [?KEY, {Target, Triggers}]),
    rabbit_ct_broker_helpers:setup_meck(Config, [?MODULE]),
    ok = rpc(Config, Node, meck, new, [rabbit_db_queue, [no_link, passthrough]]),
    ok = rpc(Config, Node, meck, expect,
             [rabbit_db_queue, get_targets, fun ?MODULE:get_targets/1]).

stop_routing(Config, Node) ->
    ok = rpc(Config, Node, meck, unload, [rabbit_db_queue]),
    true = rpc(Config, Node, persistent_term, erase, [?KEY]),
    ok.

get_targets(Names) ->
    {Target, Triggers} = persistent_term:get(?KEY),
    Name = amqqueue:get_name(Target),
    Real = meck:passthrough([Names]),
    Routed = [case N of
                  {QName, RouteInfos} when is_map(RouteInfos) -> QName;
                  QName -> QName
              end || N <- Names],
    case lists:any(fun(N) -> lists:member(N, Routed) end, [Name | Triggers]) of
        true ->
            [Target | [T || T <- Real,
                            amqqueue:get_name(rabbit_amqqueue:queue(T)) =/= Name]];
        false ->
            Real
    end.

rpc(Config, Node, M, F, A) ->
    rabbit_ct_broker_helpers:rpc(Config, Node, M, F, A).
