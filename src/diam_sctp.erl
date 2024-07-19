-module(diam_sctp).
-moduledoc """
SCTP state machine
""".

-behaviour(gen_statem).

-export([start_link/0,
         start_link/1,
         start_link/2,
         control_msg/2,
         receive_msg/2,
         send_msg/2,
         stop/1
        ]).

-export([callback_mode/0,
         init/1,
         handle_event/4,
         terminate/3
        ]).

-define(CONNECT_TIMEOUT, 1500).

-define(IPPROTO_SCTP, 132).
-define(SCTP_DEFAULT_SEND_PARAM, 10).
-define(SCTP_PPID_DIAMETER, 46).

-type opts() :: #{}.
-type name() :: atom().

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

start_link() ->
  start_link(?MODULE).

-spec start_link(name() | opts()) -> '_'.
start_link(Opts) when is_map(Opts) ->
  TOpts = maps:get(transport_options, Opts, #{}),
  start_link(maps:get(name, TOpts, ?MODULE), Opts);
start_link(SCTPName) when is_atom(SCTPName) ->
  Opts = #{
    transport_options => #{
      peer_proc => self(),
      mode => server,
      local_port => 3868,
      local_ip_addresses => ["127.0.0.1"]
      }
    },
  start_link(SCTPName, Opts).

start_link(SCTPName, Opts) ->
  gen_statem:start_link({local, SCTPName}, ?MODULE, Opts, []).

control_msg(SProc, Msg) ->
  io:format("~p:~p:~p (~p)~n", [?MODULE, SProc, ?FUNCTION_NAME, Msg]),
  gen_statem:cast(SProc, {control_msg, Msg}).

receive_msg(SProc, Msg) ->
  io:format("~p:~p:~p (~p)~n", [?MODULE, SProc, ?FUNCTION_NAME, Msg]),
  gen_statem:cast(SProc, {receive_msg, Msg}).

send_msg(SProc, Msg) ->
  io:format("~p:~p:~p (~p)~n", [?MODULE, SProc, ?FUNCTION_NAME, Msg]),
  gen_statem:cast(SProc, {send_msg, Msg}).

stop(SProc) ->
  io:format("~p:~p:~p~n", [?MODULE, SProc, ?FUNCTION_NAME]),
  gen_statem:stop(SProc).

%% ---------------------------------------------------------------------------
%% State machine
%% ---------------------------------------------------------------------------

callback_mode() ->
  [handle_event_function, state_enter].

init(AllOpts) ->
  {ok, PPid} = diam_peer:start_link(AllOpts),
  {ok, Sock} = socket:open(inet, stream, sctp),
  Data = init_data(maps:get(transport_options, AllOpts), Sock, PPid),
  bind_local_addr(Sock, Data),
  set_sctp_sndrcvinfo(Sock, maps:get(sctp_sndrcvinfo, Data, #{})),
  case maps:get(mode, Data) of
    client ->
      {ok, connect, Data, [{next_event, internal, start}]};
    server ->
      {ok, listen, Data, [{next_event, internal, start}]}
  end.

init_data(Opts, Sock, PPid) ->
  LIPAddrs = maps:get(local_ip_addresses, Opts, []),
  LPort = maps:get(local_port, Opts, 0),
  RIPAddrs = maps:get(remote_ip_addresses, Opts, []),
  RPort = maps:get(remote_port, Opts, 0),
  SndRcvInfo = maps:get(sctp_sndrcvinfo, Opts, #{ppid => ?SCTP_PPID_DIAMETER}),
  #{
    mode => maps:get(mode, Opts),
    allowed_ip_subnet => maps:get(allowed_ip_subnet, Opts, <<"0.0.0.0/0">>),
    remote_port => RPort,
    remote_ip_addresses => RIPAddrs,
    local_port => LPort,
    local_ip_addresses => LIPAddrs,
    sctp_sndrcvinfo => SndRcvInfo,
    socket => Sock,
    peer_proc => PPid
  }.

handle_event(enter, OldState, NewState, Data) ->
  Mode = maps:get(mode, Data),
  io:format("~p:~p:~p enter ~p from ~p~n", [?MODULE, Mode, self(), NewState, OldState]),
  keep_state_and_data;

%% ----- connect; client -----
handle_event(_, start, connect, Data) ->
  Caller = maps:get(peer_proc, Data),
  Sock = maps:get(socket, Data),
  RemAddrs = maps:get(remote_ip_addresses, Data),
  RemPort = maps:get(remote_port, Data),
  Addrs = [#{family => inet, addr => IP, port => RemPort}
           || IP <- RemAddrs],
  case socket:connect(Sock, hd(Addrs), ?CONNECT_TIMEOUT) of
    ok ->
      diam_peer:connect_init(Caller),
      {ok, Child} = diam_sctp_child:start_link(Sock, self()),
      diam_sctp_child:give_control(Child, Sock),
      %% {ok, Child} = spawn_child(Sock, self()),
      {next_state, open, Data#{child_proc => Child}};
    {error, timeout} ->
      {keep_state_and_data, [{next_event, internal, start}]};
    {error, econnrefused} ->
      {keep_state_and_data, [{next_event, internal, start}]};
    {error, Err} ->
      diam_peer:connect_fail(Caller, Err),
      keep_state_and_data
  end;
handle_event({timeout, connect}, _Info, connect, _Data) ->
  {repeat_state_and_data, [{next_event, internal, start}]};

%% ----- listen; server -----
handle_event(_, start, listen, Data) ->
  Caller = maps:get(peer_proc, Data),
  LSock = maps:get(socket, Data),
  ok = socket:listen(LSock),
  case socket:accept(LSock, ?CONNECT_TIMEOUT) of
    {ok, Sock1} ->
      %% remote_ip_addresses && allowed_ip_subnet check
      diam_peer:connect_init(Caller),
      {ok, Child} = diam_sctp_child:start_link(Sock1, self()),
      diam_sctp_child:give_control(Child, Sock1),
      %% {ok, Child} = spawn_child(Sock1, self()),
      {next_state, open, Data#{child_sockets => [Sock1], child_proc => Child}};
    {error, timeout} ->
      {keep_state_and_data, [{next_event, internal, start}]};
    {error, Err} ->
      diam_peer:connect_fail(Caller, Err),
      keep_state_and_data
  end;
handle_event({timeout, connect}, Info, listen, Data) ->
  LSock = maps:get(socket, Data),
  ok = socket:cancel(LSock, Info),
  {repeat_state_and_data, [{next_event, internal, start}]};

%% ----- wait for local peer -----
handle_event(_, {send_msg, Msg}, open, Data) ->
  Child = maps:get(child_proc, Data),
  diam_sctp_child:send_msg(Child, Msg),
  keep_state_and_data;
handle_event(_, {control_msg, closed}, open, Data) ->
  case maps:get(mode, Data) of
    client ->
      {next_state, connect, Data, [{next_event, internal, start}]};
    server ->
      {next_state, listen, Data, [{next_event, internal, start}]}
  end;
handle_event(_, {receive_msg, RawMsg}, open, Data) ->
  Caller = maps:get(peer_proc, Data),
  Msgs = maps:get(iov, RawMsg),
  handle_received_msgs(Caller, Msgs),
  keep_state_and_data.

terminate(_Why, _State, Data) ->
  Sock = maps:get(socket, Data),
  Socks = maps:get(child_sockets, Data, []),
  [socket:close(S) || S <- [Sock|Socks]].

%% ---------------------------------------------------------------------------
%% Help functions
%% ---------------------------------------------------------------------------

bind_local_addr(Sock, Opts) ->
  LIPAddrs = maps:get(local_ip_addresses, Opts),
  LPort = maps:get(local_port, Opts),
  bind_local_addr(Sock, LIPAddrs, LPort).

bind_local_addr(_Sock, [], _LPort) ->
  ok;
bind_local_addr(Sock, [IP|LIPAddrs], LPort) ->
  ok = socket:bind(Sock, #{family => inet, port => LPort, addr => IP}),
  bind_local_addr(Sock, LIPAddrs, LPort).

set_sctp_sndrcvinfo(Sock, SndRcvInfo) ->
  PPID = maps:get(ppid, SndRcvInfo, 0),
  TTL = maps:get(ttl, SndRcvInfo, 0),
  Context = maps:get(context, SndRcvInfo, 0),

  %% See 5.3.2. SCTP Header Information Structure (SCTP_SNDRCV) - DEPRECATED
  %% Deprecated in RFC6458, but the alternative of using a cmsg
  %% SCTP_SNDINFO is not supported by the version of sctp
  %% (lksctp-tools) that Ubuntu uses.
  SndRcvInfoBin = <<16#0000:16,
                    16#0000:16,
                    16#0000:16,
                    16#0000:16, %% one of these 16-bits shouldn't exist?
                    PPID:32,
                    Context:32, %% used for abort/error reporting
                    TTL:32, %% socket-process should be able to write to socket
                            %% within TTL, otherwise discard msg.
                    16#0000_0000:32,
                    16#0000_0000:32,
                    16#0000_0000:32>>,
  ok = socket:setopt_native(Sock, {?IPPROTO_SCTP, ?SCTP_DEFAULT_SEND_PARAM}, SndRcvInfoBin).

handle_received_msgs(_, []) ->
  ok;
handle_received_msgs(Caller, [Msg|Msgs]) ->
  case diameter_codec:decode_header(Msg) of
    false ->
      ok;
    DiamHead ->
      diam_peer:receive_msg(Caller, DiamHead, Msg)
  end,
  handle_received_msgs(Caller, Msgs).
