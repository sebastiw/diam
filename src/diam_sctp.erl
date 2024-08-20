-module(diam_sctp).
-moduledoc """
SCTP state machine
""".

-behaviour(gen_statem).

-export([start_link/1,
         start_link/2,
         control_msg/3,
         receive_msg/3,
         send_msg/2,
         send_msg/3,
         stop/1
        ]).

-export([callback_mode/0,
         init/1,
         handle_event/4,
         terminate/3
        ]).

-include_lib("diameter/include/diameter.hrl").
-define(IS_APPL_0, #diameter_header{version = 1, application_id = 0}).

-define(CONNECT_TIMEOUT, 1500).

-define(IPPROTO_SCTP, 132).
-define(SCTP_DEFAULT_SEND_PARAM, 10).
-define(SCTP_PPID_DIAMETER, 46).

-type opts() :: #{}.
-type name() :: atom().

%% ---------------------------------------------------------------------------
%% API
%% ---------------------------------------------------------------------------

-spec start_link(opts()) -> '_'.
start_link(Opts) when is_map(Opts) ->
  TOpts = maps:get(transport_options, Opts, #{}),
  start_link(maps:get(name, TOpts, ?MODULE), Opts).

-spec start_link(name(), opts()) -> '_'.
start_link(SCTPName, Opts) ->
  gen_statem:start_link({local, SCTPName}, ?MODULE, Opts, []).

control_msg(SProc, Socket, Msg) ->
  gen_statem:cast(SProc, {control_msg, Socket, Msg}).

receive_msg(SProc, Socket, Msg) ->
  gen_statem:cast(SProc, {receive_msg, Socket, Msg}).

send_msg(SProc, Msg) ->
  gen_statem:cast(SProc, {send_msg, Msg}).

send_msg(SProc, Socket, Msg) ->
  gen_statem:cast(SProc, {send_msg, Socket, Msg}).

stop(SProc) ->
  gen_statem:stop(SProc).

%% ---------------------------------------------------------------------------
%% State machine
%% ---------------------------------------------------------------------------

callback_mode() ->
  [handle_event_function, state_enter].

init(AllOpts) ->
  Data = init_data(AllOpts),
  NewData = new_socket(Data),
  case maps:get(mode, NewData) of
    client ->
      {ok, connect, NewData, [{next_event, internal, start}]};
    server ->
      {ok, listen, NewData, [{next_event, internal, start}]}
  end.

init_data(AllOpts) ->
  Opts = maps:get(transport_options, AllOpts),
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
    all_options => AllOpts
  }.

handle_event(enter, OldState, NewState, Data) ->
  Mode = maps:get(mode, Data),
  io:format("~p:~p:~p enter ~p from ~p~n", [?MODULE, Mode, self(), NewState, OldState]),
  keep_state_and_data;

%% ----- connect; client -----
handle_event(_, start, connect, Data) ->
  Sock = maps:get(socket, Data),
  case connect(Data, Sock) of
    ok ->
      NewData = ack_and_start_child(Data, Sock),
      {next_state, open, NewData};
    {error, timeout} ->
      {keep_state_and_data, [{next_event, internal, start}]};
    {error, econnrefused} ->
      timer:sleep(?CONNECT_TIMEOUT),
      {keep_state_and_data, [{next_event, internal, start}]};
    {error, closed} ->
      NewData = new_socket(Data),
      {keep_state, NewData, [{next_event, internal, start}]};
    {error, Err} ->
      Peer = get_peer(Data, Sock),
      diam_peer:connect_fail(Peer, Sock, Err),
      keep_state_and_data
  end;
handle_event({timeout, connect}, _Info, connect, _Data) ->
  {repeat_state_and_data, [{next_event, internal, start}]};

%% ----- listen; server -----
handle_event(_, start, listen, Data) ->
  case accept(Data, ?CONNECT_TIMEOUT) of
    {ok, Sock1} ->
      %% remote_ip_addresses && allowed_ip_subnet check
      NewData = ack_and_start_child(Data, Sock1),
      {ok, TRef} = timer:send_after(?CONNECT_TIMEOUT, {accept_timeout, nowait}),
      {next_state, open, NewData#{accept_tref => TRef}};
    {error, timeout} ->
      io:format("~p:~p:~p~n", [?MODULE, accept_timeout, self()]),
      {keep_state_and_data, [{next_event, internal, start}]};
    {error, Err} ->
      io:format("~p:~p:~p ~p~n", [?MODULE, accept_error, self(), Err]),
      {keep_state_and_data, [{next_event, internal, start}]}
  end;
handle_event({timeout, connect}, Info, listen, Data) ->
  LSock = maps:get(socket, Data),
  ok = socket:cancel(LSock, Info),
  {repeat_state_and_data, [{next_event, internal, start}]};

%% ----- wait for local peer -----
handle_event(_, {send_msg, Msg}, open, Data) ->
  CS = maps:to_list(maps:get(child_sockets, Data)),
  Random = rand:uniform(length(CS)),
  {_, Child} = lists:nth(Random, CS),
  diam_sctp_child:send_msg(Child, Msg),
  keep_state_and_data;
handle_event(_, {send_msg, Socket, Msg}, open, Data) ->
  CS = maps:get(child_sockets, Data),
  Child = maps:get(Socket, CS),
  diam_sctp_child:send_msg(Child, Msg),
  keep_state_and_data;
handle_event(_, {control_msg, Sock, closed}, open, Data) ->
  AcceptTRef = maps:get(accept_tref, Data, undefined),
  timer:cancel(AcceptTRef),
  Peer = get_peer(Data, Sock),
  diam_peer:connect_fail(Peer, Sock, closed),
  case maps:get(mode, Data) of
    client ->
      {next_state, connect, Data, [{next_event, internal, start}]};
    server ->
      {next_state, listen, Data, [{next_event, internal, start}]}
  end;
handle_event(_, {receive_msg, Socket, RawMsg}, open, Data) ->
  Peer = get_peer(Data, Socket),
  WdPid = get_wd(Peer, Data),
  Msgs = maps:get(iov, RawMsg),
  handle_received_msgs({Peer, Socket, WdPid}, Msgs),
  keep_state_and_data;
handle_event(info, {accept_timeout, Select}, open, Data) ->
  {ok, cancel} = timer:cancel(maps:get(accept_tref, Data)),
  case accept(Data, Select) of
    {ok, Sock1} ->
      NewData = ack_and_start_child(Data, Sock1),
      {ok, TRef} = timer:send_after(?CONNECT_TIMEOUT, {accept_timeout, nowait}),
      {keep_state, NewData#{accept_tref => TRef}};
    {select, {select_info, accept, SelectInfo}} ->
      {ok, TRef} = timer:send_after(?CONNECT_TIMEOUT, {accept_timeout, SelectInfo}),
      {keep_state, Data#{accept_tref => TRef}};
    {error, Reason} ->
      io:format("~p:~p:~p ~p~n", [?MODULE, accept_timeout, self(), Reason]),
      {ok, TRef} = timer:send_after(?CONNECT_TIMEOUT, {accept_timeout, nowait}),
      {keep_state, Data#{accept_tref => TRef}}
  end;
handle_event(info, {'$socket', LSock, select, Ref}, open, #{socket := LSock} = Data) ->
  {ok, cancel} = timer:cancel(maps:get(accept_tref, Data)),
  case accept(Data, Ref) of
    {ok, Sock1} ->
      NewData = ack_and_start_child(Data, Sock1),
      {ok, TRef} = timer:send_after(?CONNECT_TIMEOUT, {accept_timeout, nowait}),
      {keep_state, NewData#{accept_tref => TRef}}
  end;
handle_event(info, {'$socket', Sock, abort, {_Ref, cancelled}}, open, #{socket := Sock} = Data) ->
  {keep_state, Data};
handle_event(EventType, EventContent, State, Data) ->
  {keep_state, Data}.

terminate(_Why, _State, Data) ->
  Sock = maps:get(socket, Data),
  Socks = maps:keys(maps:get(child_sockets, Data, #{})),
  [socket:close(S) || S <- [Sock|Socks]].

%% ---------------------------------------------------------------------------
%% Actions
%% ---------------------------------------------------------------------------

connect(Data, Sock) ->
  RemAddrs = maps:get(remote_ip_addresses, Data),
  RemPort = maps:get(remote_port, Data),
  Addrs = [#{family => inet, addr => IP, port => RemPort}
           || IP <- RemAddrs],
  socket:connect(Sock, hd(Addrs), ?CONNECT_TIMEOUT).

accept(Data, Timeout) when is_integer(Timeout) ->
  LSock = maps:get(socket, Data),
  %% If LSock have died, socket:listen returns {error,closed}
  ok = socket:listen(LSock),
  socket:accept(LSock, ?CONNECT_TIMEOUT);
accept(Data, Ref) ->
  LSock = maps:get(socket, Data),
  socket:accept(LSock, Ref).

ack_and_start_child(Data, Sock) ->
  PPid = get_or_start_peer(Data),
  AllOpts = maps:get(all_options, Data),
  POpts = maps:get(peer_options, AllOpts, #{}),
  PeerName = maps:get(name, POpts, peer1),
  WdPid = get_or_start_watchdog(#{name => PeerName, peer_pid => PPid, socket => Sock, all_options => AllOpts, tproc => self()}),
  {ok, Child} = diam_sctp_child:start_link(Sock, self()),
  diam_sctp_child:give_control(Child, Sock),
  diam_peer:connect_init(PPid, Sock),
  add_peer(Data, Sock, PPid, Child, WdPid).

%% ---------------------------------------------------------------------------
%% Help functions
%% ---------------------------------------------------------------------------

new_socket(Data) ->
  {ok, Sock} = socket:open(inet, stream, sctp),
  bind_local_addr(Sock, Data),
  set_sctp_sndrcvinfo(Sock, maps:get(sctp_sndrcvinfo, Data, #{})),
  set_sock(Data, Sock).

add_peer(Data, Sock, PPid, Child, WdPid) ->
  PProcs = maps:get(peer_procs, Data, #{}),
  Children = maps:get(child_sockets, Data, #{}),
  WdProcs = maps:get(wd_procs, Data, #{}),
  Data#{
    peer_procs => PProcs#{Sock => PPid},
    wd_procs => WdProcs#{PPid => WdPid},
    child_sockets => Children#{Sock => Child}
    }.

get_peer(Data, Socket) ->
  PProcs = maps:get(peer_procs, Data),
  maps:get(Socket, PProcs).

get_wd(Peer, Data) ->
    WdProcs = maps:get(wd_procs, Data),
    maps:get(Peer, WdProcs).

get_or_start_peer(Data) ->
  case diam_peer:start_link(maps:get(all_options, Data)) of
    {ok, PPid} ->
      PPid;
    {error, {already_started, PPId}} ->
      PPId
  end.

get_or_start_watchdog(Data) ->
  case diam_watchdog:start(Data) of
    {ok, WdPid} ->
      WdPid;
    {error, {already_started, WdPid}} ->
      diam_watchdog:update_state(WdPid, Data),
      WdPid
  end.

set_sock(Data, Sock) ->
  Data#{
    socket => Sock
    }.

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
handle_received_msgs({Peer, Socket, WdPid}, [Msg|Msgs]) ->
  DiamHead = diameter_codec:decode_header(Msg),
  diam_watchdog:reset_watchdog_timer(WdPid, DiamHead),
  case DiamHead of
    false ->
      io:format("Not diameter ~p~n", [Msg]),
      ok;
    ?IS_APPL_0 ->
      diam_peer:receive_msg(Peer, Socket, DiamHead, Msg);
    _ ->
      %% Callback/other process?
      io:format("Not implemented ~p~n", [DiamHead])
  end,
  handle_received_msgs({Peer, Socket, WdPid}, Msgs).
