%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2012, 2013 VMware, Inc.  All rights reserved.
%%

-module(rabbit_jms_topic_exchange).

-behaviour(rabbit_exchange_type).

-export([description/0
        ,serialise_events/0
        ,route/2
        ]).
-export([validate/1
        ,create/2
        ,delete/3
        ,add_binding/3
        ,remove_bindings/3
        ,assert_args_equivalence/2
        ]).

-rabbit_boot_step({?MODULE
                  ,[{description,"JMS topic exchange type"}
                   ,{mfa        ,{rabbit_registry
                                 ,register
                                 ,[exchange, <<"x-jms-topic">>, ?MODULE]
                                 }
                    }
                   ,{requires   ,rabbit_registry}
                   ,{enables    ,kernel_ready   }
                   ]
                  }).

-define(EXCHANGE, <<"x-jms-topic-exchange">>).

-include_lib("rabbit_common/include/rabbit.hrl").

%%----------------------------------------------------------------------------

description() -> [{name, <<"jms-topic">>},
                  {description, <<"JMS topic exchange">>}
                 ].

serialise_events() -> false.

route(#exchange{name = Name}, _Delivery) ->
    rabbit_router:match_routing_key(Name, ['_']).

validate(_X) -> ok.
create(_Tx, _X) -> ok.
delete(_Tx, _X, _Bs) -> ok.
add_binding(_Tx, _X, _B) -> ok.
remove_bindings(_Tx, _X, _Bs) -> ok.
assert_args_equivalence(X, Args) ->
    rabbit_exchange:assert_args_equivalence(X, Args).

%%----------------------------------------------------------------------------


%%----------------------------------------------------------------------------
