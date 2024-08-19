-module(diam_msgs).
-moduledoc """
  Construct Diameter Application 0 message binaries.
""".

-export([decode/2,
         cer/5,
         cea/6,
         dwr/4,
         dwa/5,
         dpr/4,
         dpa/5
        ]).

-include_lib("diameter/include/diameter.hrl").
-include_lib("diam/include/diam.hrl").

-define(PAD_LEN(Len), (8*((4 - ((Len) rem 4)) rem 4))).
-define(ZERO_PAD(ByteLen), 0:?PAD_LEN(ByteLen)).
-define(SET_AVP_FLAGS(V, M, P), V:1, M:1, P:1, 0:5).
-define(GET_AVP_FLAGS(V, M, P), V:1, M:1, P:1, _:5).

%% ---------------------------------------------------------------------------
%% Decode
%% ---------------------------------------------------------------------------

decode(?CER, Msg) ->
  AVPMap = decode(Msg),
  #{
    'Origin-Host' => maps:get({0, 264}, AVPMap),
    'Origin-Realm' => maps:get({0, 296}, AVPMap),
    'Host-IP-Address' => maps:get({0, 257}, AVPMap),
    'Vendor-Id' => maps:get({0, 266}, AVPMap),
    'Product-Name' => maps:get({0, 269}, AVPMap),
    'Supported-Vendor-Id' => maps:get({0, 265}, AVPMap),
    'Auth-Application-Id' => maps:get({0, 258}, AVPMap),
    'Acct-Application-Id' => maps:get({0, 259}, AVPMap)
    };
decode(?CEA, Msg) ->
  AVPMap = decode(Msg),
  #{
    'Result-Code' => maps:get({0, 268}, AVPMap),
    'Origin-Host' => maps:get({0, 264}, AVPMap),
    'Origin-Realm' => maps:get({0, 296}, AVPMap),
    'Host-IP-Address' => maps:get({0, 257}, AVPMap),
    'Vendor-Id' => maps:get({0, 266}, AVPMap),
    'Product-Name' => maps:get({0, 269}, AVPMap),
    'Supported-Vendor-Id' => maps:get({0, 265}, AVPMap),
    'Auth-Application-Id' => maps:get({0, 258}, AVPMap),
    'Acct-Application-Id' => maps:get({0, 259}, AVPMap)
    };
decode(?DWR, Msg) ->
  AVPMap = decode(Msg),
  #{
    'Origin-Host' => maps:get({0, 264}, AVPMap),
    'Origin-Realm' => maps:get({0, 296}, AVPMap)
    }.

decode(<<_Header:20/binary, Data/binary>>) ->
  AVPs = decode_avps(Data, []),
  maps:groups_from_list(fun (X) -> element(1, X) end, fun (X) -> element(2, X) end, AVPs).

decode_avps(<<>>, Acc) ->
  Acc;
decode_avps(<<Code:32, ?GET_AVP_FLAGS(0, M, _), Len:24, Value:(Len-8)/binary, _:?PAD_LEN(Len-8), Next/binary>>, Acc) ->
  A = {{0, Code}, {1 == M, Value}},
  decode_avps(Next, [A|Acc]);
decode_avps(<<Code:32, ?GET_AVP_FLAGS(1, M, _), Len:24, VendorId:32, Value:(Len-12)/binary, _:?PAD_LEN(Len-8), Next/binary>>, Acc) ->
  A = {{VendorId, Code}, {1 == M, Value}},
  decode_avps(Next, [A|Acc]).

%% ---------------------------------------------------------------------------
%% Encode Messages
%% ---------------------------------------------------------------------------

cer(Host, Realm, HBH, E2E, IPAddrs) ->
  AVPs = [
          'Origin-Host'(Host),
          'Origin-Realm'(Realm)
         ]
    ++ ['Host-IP-Address'(IP) || IP <- IPAddrs]
    ++ [
        'Vendor-Id'(),
        'Product-Name'(),
        'Supported-Vendor-Id'(0),
        'Supported-Vendor-Id'(10415),
        'Auth-Application-Id'(),
        'Acct-Application-Id'()
       ],
  msg(257, AVPs, true, HBH, E2E).

cea(Host, Realm, HBH, E2E, IPAddrs, Result) ->
  AVPs = [
          'Result-Code'(Result),
          'Origin-Host'(Host),
          'Origin-Realm'(Realm)
         ]
    ++ ['Host-IP-Address'(IP) || IP <- IPAddrs]
    ++ [
        'Vendor-Id'(),
        'Product-Name'(),
        'Supported-Vendor-Id'(0),
        'Supported-Vendor-Id'(10415),
        'Auth-Application-Id'(),
        'Acct-Application-Id'()
       ],
  %% [ Error-Message ]
  %% [ Failed-AVP ]
  msg(257, AVPs, false, HBH, E2E).

dwr(Host, Realm, HBH, E2E) ->
  AVPs = [
          'Origin-Host'(Host),
          'Origin-Realm'(Realm)
         ],
  msg(280, AVPs, true, HBH, E2E).

dwa(Host, Realm, HBH, E2E, Result) ->
  AVPs = [
          'Result-Code'(Result),
          'Origin-Host'(Host),
          'Origin-Realm'(Realm)
         ],
  %% [ Error-Message ]
  %% [ Failed-AVP ]
  msg(280, AVPs, false, HBH, E2E).

dpr(Host, Realm, HBH, E2E) ->
  AVPs = [
          'Origin-Host'(Host),
          'Origin-Realm'(Realm),
          'Disconnect-Cause'()
         ],
  msg(282, AVPs, true, HBH, E2E).

dpa(Host, Realm, HBH, E2E, Result) ->
  AVPs = [
          'Result-Code'(Result),
          'Origin-Host'(Host),
          'Origin-Realm'(Realm)
         ],
  %% [ Error-Message ]
  %% [ Failed-AVP ]
  msg(282, AVPs, false, HBH, E2E).

%% ---------------------------------------------------------------------------
%% AVPs
%% ---------------------------------------------------------------------------

'Origin-Host'(V) ->
  avp(264, 1, V).

'Origin-Realm'(V) ->
  avp(296, 1, V).

'Host-IP-Address'({A,B,C,D}) ->
  avp(257, 1, <<1:16, A, B, C, D>>).

'Vendor-Id'() ->
  avp(266, 1, <<55247:32>>).

'Product-Name'() ->
  V = <<"Starlet">>,
  avp(269, 0, V).

'Supported-Vendor-Id'(V) ->
  avp(265, 1, <<V:32>>).

'Auth-Application-Id'() ->
  avp(258, 1, <<16#FFFF_FFFF:32>>).

'Acct-Application-Id'() ->
  avp(259, 1, <<16#FFFF_FFFF:32>>).

'Result-Code'(V) ->
  avp(268, 1, <<V:32>>).

'Disconnect-Cause'() ->
  %% 0: REBOOTING,
  %% 1: BUSY,
  %% 2: DO_NOT_WANT_TO_TALK_TO_YOU
  avp(273, 1, <<0:32>>).

%% ---------------------------------------------------------------------------
%% Help functions
%% ---------------------------------------------------------------------------

%%  0                   1                   2                   3
%%  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% | Version | Message Length                                      |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% | Command Flags | Command Code                                  |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% | Application-ID                                                |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% | Hop-by-Hop Identifier                                         |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% | End-to-End Identifier                                         |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% | AVPs ...
%% +-+-+-+-+-+-+-+-+-+-+-+-+-

msg(Cmd, AVPs, IsReq, HBH, E2E) ->
  M = list_to_binary(AVPs),
  R = case IsReq of
          true -> 1;
          false -> 0
      end,
  H = header(Cmd, byte_size(M), R, HBH, E2E),
  <<H/binary, M/binary>>.

header(Cmd, MsgLen, R, HBH, E2E) ->
  L = 20 + MsgLen,
  <<1:8, L:24,
    R:1, 2#000_0000:7, Cmd:24,
    0:32,
    (HBH rem 16#FFFF_FFFF):32,
    (E2E rem 16#FFFF_FFFF):32>>.


%%  0                   1                   2                   3
%%  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% | AVP Code                                                      |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% |V M P r r r r r| AVP Length                                    |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% | Vendor-ID (opt)                                               |
%% +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
%% | Data ...
%% +-+-+-+-+-+-+-+-+

avp(Code, Mbit, Value) ->
  Len = 8 + byte_size(Value),
  <<Code:32, ?SET_AVP_FLAGS(0, Mbit, 0), Len:24, Value/binary, ?ZERO_PAD(Len)>>.
