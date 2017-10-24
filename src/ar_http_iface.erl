-module(ar_http_iface).
-export([start/0, start/1, start/2, handle/2, handle_event/3]).
-export([send_new_block/4, send_new_tx/2, get_block/2]).
-include("ar.hrl").
-include("../lib/elli/include/elli.hrl").
-include_lib("eunit/include/eunit.hrl").

%%% Exposes access to an internal Archain network to external nodes.

%% @doc Start the interface.
start() -> start(?DEFAULT_HTTP_IFACE_PORT).
start(Port) ->
	spawn(
		fun() ->
			{ok, PID} = elli:start_link([{callback, ?MODULE}, {port, Port}]),
			receive stop -> elli:stop(PID) end
		end
	).
start(Port, Node) ->
	reregister(Node),
	start(Port).

%%% Server side functions.

%% @doc Handle a request to the server.
handle(Req, _Args) ->
	handle(Req#req.method, elli_request:path(Req), Req).

handle('GET', [<<"api">>], _Req) ->
	{200, [], <<"OK">>};
handle('POST', [<<"api">>, <<"block">>], Req) ->
	BlockJSON = elli_request:body(Req),
	{ok, {struct, Struct}} = json2:decode_string(binary_to_list(BlockJSON)),
	{"recall_block", JSONRecallB} = lists:keyfind("recall_block", 1, Struct),
	{"new_block", JSONB} = lists:keyfind("new_block", 1, Struct),
	{"port", Port} = lists:keyfind("port", 1, Struct),
	B = ar_serialize:json_struct_to_block(JSONB),
	RecallB = ar_serialize:json_struct_to_block(JSONRecallB),
	%ar:report_console([{recvd_block, B#block.height}, {port, Port}]),
	ar_node:add_block(
		whereis(http_entrypoint_node),
		ar_util:parse_peer(
			bitstring_to_list(elli_request:peer(Req))
			++ ":"
			++ integer_to_list(Port)
		),
		B,
		RecallB,
		B#block.height
	),
	{200, [], <<"OK">>};
handle('POST', [<<"api">>, <<"tx">>], Req) ->
	TXJSON = elli_request:body(Req),
	TX = ar_serialize:json_struct_to_tx(binary_to_list(TXJSON)),
	%ar:report(TX),
	Node = whereis(http_entrypoint_node),
	ar_node:add_tx(Node, TX),
	{200, [], <<"OK">>};
handle('GET', [<<"api">>, <<"block">>, <<"hash">>, Hash], _Req) ->
	%ar:report_console([{resp_getting_block_by_hash, Hash}, {path, elli_request:path(Req)}]),
	return_block(
		ar_node:get_block(whereis(http_entrypoint_node),
			ar_util:dehexify(Hash))
	);
handle('GET', [<<"api">>, <<"block">>, <<"height">>, Height], _Req) ->
	%ar:report_console([{resp_getting_block, list_to_integer(binary_to_list(Height))}]),
	return_block(
		ar_node:get_block(whereis(http_entrypoint_node),
			list_to_integer(binary_to_list(Height)))
	);
handle(_, _, _) ->
	{500, [], <<"Request type not found.">>}.

%% @doc Handles elli metadata events.
handle_event(Event, Data, Args) ->
	ar:report([{elli_event, Event}, {data, Data}, {args, Args}]),
	ok.

%% @doc Return a block via HTTP.
return_block(unavailable) -> {404, [], <<"Block not found.">>};
return_block(B) ->
	{200, [],
		list_to_binary(
			ar_serialize:jsonify(
				ar_serialize:block_to_json_struct(B)
			)
		)
	}.

%%% Client functions

%% @doc Send a new transaction to an Archain HTTP node.
send_new_tx(Host, TX) ->
	httpc:request(
		post,
		{
			"http://" ++ ar_util:format_peer(Host) ++ "/api/tx",
			[],
			"application/x-www-form-urlencoded",
			ar_serialize:jsonify(ar_serialize:tx_to_json_struct(TX))
		}, [], []
	).

%% @doc Distribute a newly found block to remote nodes.
send_new_block(Host, Port, NewB, RecallB) ->
	%ar:report_console([{sending_new_block, NewB#block.height}, {stack, erlang:get_stacktrace()}]),
	httpc:request(
		post,
		{
			"http://" ++ ar_util:format_peer(Host) ++ "/api/block",
			[],
			"application/x-www-form-urlencoded",
			lists:flatten(
				ar_serialize:jsonify(
					{struct,
						[
							{new_block,
								ar_serialize:block_to_json_struct(NewB)},
							{recall_block,
								ar_serialize:block_to_json_struct(RecallB)},
							{port, Port}
						]
					}
				)
			)
		}, [], []
	).

%% @doc Retreive a block (by height or hash) from a node.
get_block(Host, Height) when is_integer(Height) ->
	%ar:report_console([{req_getting_block_by_height, Height}]),
	handle_block_response(
		httpc:request(
			"http://"
				++ ar_util:format_peer(Host)
				++ "/api/block/height/"
				++ integer_to_list(Height)));
get_block(Host, Hash) when is_binary(Hash) ->
	%ar:report_console([{req_getting_block_by_hash, Hash}]),
	handle_block_response(
		httpc:request(
			"http://"
				++ ar_util:format_peer(Host)
				++ "/api/block/hash/"
				++ ar_util:hexify(Hash))).

%% @doc Process the response of an /api/block call.
handle_block_response({ok, {{_, 200, _}, _, Body}}) ->
	ar_serialize:json_struct_to_block(Body);
handle_block_response({ok, {{_, 404, _}, _, _}}) ->
	not_found.



%% @doc Helper function : registers a new node as the entrypoint.
reregister(Node) ->
	case erlang:whereis(http_entrypoint_node) of
		undefined -> do_nothing;
		_ -> erlang:unregister(http_entrypoint_node)
	end,
	erlang:register(http_entrypoint_node, Node).

%%% Tests

%% @doc Ensure that blocks can be received via a hash.
get_block_by_hash_test() ->
	[B0] = ar_weave:init(),
	Node1 = ar_node:start([], [B0]),
	reregister(Node1),
	receive after 200 -> ok end,
	B0 = get_block({127, 0, 0, 1}, B0#block.hash).

%% @doc Ensure that blocks can be received via a height.
get_block_by_height_test() ->
	[B0] = ar_weave:init(),
	Node1 = ar_node:start([], [B0]),
	reregister(Node1),
	B0 = get_block({127, 0, 0, 1}, 0).

%% @doc Test adding transactions to a block.
add_external_tx_test() ->
	[B0] = ar_weave:init(),
	Node = ar_node:start([], [B0]),
	reregister(Node),
	send_new_tx({127, 0, 0, 1}, TX = ar_tx:new(<<"DATA">>)),
	receive after 1000 -> ok end,
	ar_node:mine(Node),
	receive after 1000 -> ok end,
	[B1|_] = ar_node:get_blocks(Node),
	[TX] = B1#block.txs.

%% @doc Ensure that blocks can be added to a network from outside
%% a single node.
add_external_block_test() ->
	[B0] = ar_weave:init(),
	Node1 = ar_node:start([], [B0]),
	reregister(Node1),
	Node2 = ar_node:start([], [B0]),
	ar_node:mine(Node2),
	receive after 1000 -> ok end,
	[B1|_] = ar_node:get_blocks(Node2),
	send_new_block({127, 0, 0, 1}, ?DEFAULT_HTTP_IFACE_PORT, B1, B0),
	receive after 500 -> ok end,
	[B1, B0] = ar_node:get_blocks(Node1).