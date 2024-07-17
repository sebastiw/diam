-module(diam_sup).

-behaviour(supervisor).

-export([start_link/0
        ]).

-export([init/1
        ]).

-spec start_link() -> {ok, pid()}.
start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init(_) ->
  SupFlags = #{strategy => one_for_one, intensity => 1, period => 5},
  ChildSpecs = [],
  {ok, {SupFlags, ChildSpecs}}.

