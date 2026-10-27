%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2026 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

%% `connection_max_per_node': one connection limit shared by every messaging
%% protocol on the node, counted in a node-local `pg' scope.
-module(amq_connection_limit).

-export([start_scope/0,
         register_connection/0,
         count/0,
         over_limit/0,
         at_limit/0]).

-rabbit_boot_step({?MODULE,
                   [{description, "local-only pg scope for connection_max_per_node"},
                    {mfa,         {?MODULE, start_scope, []}},
                    {requires,    kernel_ready},
                    {enables,     core_initialized}]}).

-define(PT_SCOPE, {?MODULE, scope}).

-spec start_scope() -> ok | {error, supervisor:startchild_err()}.
start_scope() ->
    Scope = rabbit:pg_local_scope(?MODULE),
    persistent_term:put(?PT_SCOPE, Scope),
    rabbit_sup:start_child(?MODULE, pg, [Scope]).

%% Called by the connection process itself. `pg' removes it when it exits.
-spec register_connection() -> ok.
register_connection() ->
    Pid = self(),
    pg:join(persistent_term:get(?PT_SCOPE), Pid, Pid).

%% Every member is its own group, so the table holds one row per connection.
-spec count() -> non_neg_integer().
count() ->
    case ets:info(persistent_term:get(?PT_SCOPE, undefined), size) of
        N when is_integer(N) -> N;
        undefined -> 0
    end.

%% Called by the connection being admitted, which joins here if its transport
%% did not register it. A connection refused by this check leaves, so it does
%% not hold a place while it closes.
-spec over_limit() -> false | {true, integer()}.
over_limit() ->
    case limit() of
        infinity ->
            false;
        Limit ->
            Scope = persistent_term:get(?PT_SCOPE),
            Pid = self(),
            case pg:get_local_members(Scope, Pid) of
                [] -> ok = register_connection();
                _ -> ok
            end,
            case count() > Limit of
                true ->
                    _ = pg:leave(Scope, Pid, Pid),
                    {true, Limit};
                false ->
                    false
            end
    end.

%% For health checks, which ask whether one more connection would be admitted.
-spec at_limit() -> false | {true, non_neg_integer(), integer()}.
at_limit() ->
    case limit() of
        infinity -> false;
        Limit -> Count = count(),
                 case Count >= Limit of
                     true -> {true, Count, Limit};
                     false -> false
                 end
    end.

limit() ->
    case application:get_env(rabbit, connection_max_per_node, infinity) of
        Limit when is_integer(Limit) -> Limit;
        _ -> infinity
    end.
