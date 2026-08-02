%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2026 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%

%% Exposes node-wide aggregates of the metrics osiris keeps for streams:
%% the histograms of entry, sub-batch and chunk sizes, and a fold over
%% every stream writer on the node for replication health.
%%
%% Everything here is an aggregate rather than a per-stream series, so the
%% cardinality is fixed whatever the number of streams and these belong in
%% the default registry. Per-stream stream metrics live in
%% prometheus_rabbitmq_core_metrics_collector.
-module(prometheus_rabbitmq_stream_metrics_collector).

-behaviour(prometheus_collector).
-include_lib("prometheus/include/prometheus.hrl").

-export([register/0,
         deregister_cleanup/1,
         collect_mf/2]).

-define(METRIC_NAME_PREFIX, "rabbitmq_stream_").

%% the seshat group osiris registers its metrics in
-define(GROUP, osiris).

register() ->
    ok = prometheus_registry:register_collector(?MODULE).

deregister_cleanup(_) ->
    ok.

collect_mf(_Registry, Callback) ->
    maps:foreach(
      fun(Name, #{type := Type,
                  help := Help,
                  values := Values}) ->
              MetricsFamily = prometheus_model_helpers:create_mf(
                                ?METRIC_NAME(Name), Help, Type, Values),
              Callback(MetricsFamily)
      end,
      metrics()).

metrics() ->
    try
        maps:merge(seshat_histogram:format(?GROUP), writer_metrics())
    catch
        error:badarg ->
            %% the osiris application has not registered its metrics group
            #{}
    end.

writer_metrics() ->
    {Staleness, Backlog} = fold_writers(),
    #{replica_staleness_max_seconds =>
          #{type => gauge,
            help => "Largest timestamp difference between the last chunk "
                    "written and the oldest last chunk of any replica, over "
                    "every stream writer on this node",
            %% osiris keeps this in milliseconds; Prometheus wants base units
            values => [Staleness / 1000]},
      replication_backlog =>
          #{type => gauge,
            help => "Offsets written but not yet confirmed by a replica, "
                    "summed over every stream writer on this node",
            values => [Backlog]}}.

fold_writers() ->
    seshat:fold(
      fun ({osiris_writer, _}, Values, {Staleness, Backlog}) ->
              {max(Staleness, field(replica_staleness, Values)),
               Backlog + field(replication_backlog, Values)};
          (_Id, _Values, Acc) ->
              %% replicas and replica readers register in this group too
              Acc
      end, {0, 0}, ?GROUP, [replica_staleness, replication_backlog]).

%% Tolerate a writer whose fields spec lacks one of these: collect_mf/2
%% runs on every scrape, and a missing counter is not worth failing over.
field(Name, Values) ->
    maps:get(Name, Values, 0).
