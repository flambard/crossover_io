-module(crossover_io_server).
-behaviour(gen_server).

%%
%%                      Crossover I/O server
%%   I/O client A         +-------------+         I/O client B
%% +--------------+       |             |       +--------------+
%% |        out ->|------>|----\   /----|<------|<- out        |
%% |              |       |     \ /     |       |              |
%% |              |       |      X      |       |              |
%% |              |       |     / \     |       |              |
%% |         in <-|<------|<---/   \--->|------>|-> in         |
%% +--------------+       |             |       +--------------+
%%                        +-------------+
%%
%%

%% API
-export([
    start_link/1,
    clients/1,
    set_reader/3,
    add_writer/3
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2
]).

%%%
%%% API
%%%

start_link(Options) ->
    gen_server:start_link(?MODULE, [], Options).

clients(Server) ->
    gen_server:call(Server, clients).

set_reader(Server, Side, Pid) ->
    gen_server:call(Server, {set_reader, Side, Pid}).

add_writer(Server, Side, Pid) ->
    gen_server:call(Server, {add_writer, Side, Pid}).

%%%
%%% gen_server callbacks
%%%

-record(side, {
    reader = undefined,
    writers = sets:new(),
    waiting_read = undefined,
    reply_as = undefined,
    buffer = <<>>
}).

init([]) ->
    State = #{
        client_a => #side{},
        client_b => #side{}
    },
    {ok, State}.

handle_call(clients, _From, State) ->
    #{
        client_a := #side{reader = AReader, writers = AWriters},
        client_b := #side{reader = BReader, writers = BWriters}
    } = State,
    Reply = #{
        client_a => #{reader => AReader, writers => sets:to_list(AWriters)},
        client_b => #{reader => BReader, writers => sets:to_list(BWriters)}
    },
    {reply, Reply, State};
handle_call({set_reader, Side, Pid}, _From, State) ->
    #{Side := S} = State,
    UpdatedSide = S#side{reader = Pid, writers = sets:add_element(Pid, S#side.writers)},
    {reply, ok, State#{Side := UpdatedSide}};
handle_call({add_writer, Side, Pid}, _From, State) ->
    #{Side := S} = State,
    UpdatedSide = S#side{writers = sets:add_element(Pid, S#side.writers)},
    {reply, ok, State#{Side := UpdatedSide}}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({io_request, From, ReplyAs, Request}, State) ->
    case io_request_type(Request) of
        read ->
            {Side, NewState} =
                case reader_side(State, From) of
                    undefined ->
                        {ok, {S, State1}} = register_reader_writer(State, From),
                        {S, State1};
                    {ok, S} ->
                        {S, State}
                end,
            {noreply, handle_io_read(Request, Side, From, ReplyAs, NewState)};
        write ->
            {OtherSide, NewState} =
                case writer_side(State, From) of
                    undefined ->
                        {ok, {Side, State1}} = register_reader_writer(State, From),
                        {other(Side), State1};
                    {ok, Side} ->
                        {other(Side), State}
                end,
            {noreply, handle_io_write(Request, OtherSide, From, ReplyAs, NewState)}
    end;
handle_info(Message, State) ->
    logger:warning("Unexpected message to Crossover IO server: ~p", [Message]),
    {noreply, State}.

%%%
%%% Private functions
%%%

io_request_type({put_chars, _Encoding, _Characters}) -> write;
io_request_type({put_chars, _Encoding, _Module, _Function, _Args}) -> write;
io_request_type({get_until, _Encoding, _Prompt, _Module, _Function, _ExtraArgs}) -> read;
io_request_type({get_chars, _Encoding, _Prompt, _N}) -> read;
io_request_type({get_line, _Encoding, _Prompt}) -> read.

reader_side(State, Pid) ->
    case State of
        #{client_a := #side{reader = Pid}} -> {ok, client_a};
        #{client_b := #side{reader = Pid}} -> {ok, client_b};
        _ -> undefined
    end.

writer_side(State, Pid) ->
    #{
        client_a := #side{writers = AWriters},
        client_b := #side{writers = BWriters}
    } = State,

    case sets:is_element(Pid, AWriters) of
        true ->
            {ok, client_a};
        false ->
            case sets:is_element(Pid, BWriters) of
                true -> {ok, client_b};
                false -> undefined
            end
    end.

register_reader_writer(State, Pid) ->
    case State of
        #{client_a := #side{reader = undefined, writers = Writers} = C} ->
            UpdatedClient = C#side{reader = Pid, writers = sets:add_element(Pid, Writers)},
            {ok, {client_a, State#{client_a := UpdatedClient}}};
        #{client_b := #side{reader = undefined, writers = Writers} = C} ->
            UpdatedClient = C#side{reader = Pid, writers = sets:add_element(Pid, Writers)},
            {ok, {client_b, State#{client_b := UpdatedClient}}};
        _ ->
            {error, cannot_determine_which_side}
    end.

handle_io_read({get_chars, latin1, _Prompt, N}, Side, From, ReplyAs, State) ->
    %%
    %% IF there are enough bytes in the buffer
    %% THEN pop the bytes from the buffer and send it
    %% ELSE store the request and reply_as reference
    %%
    #{
        Side := #side{reader = From, buffer = Buffer} = C
    } = State,

    UpdatedSide =
        case Buffer of
            <<Bytes:N/binary, Rest/binary>> ->
                From ! {io_reply, ReplyAs, Bytes},
                C#side{buffer = Rest};
            <<Buffer/binary>> ->
                C#side{waiting_read = {get_chars, latin1, N}, reply_as = ReplyAs}
        end,
    State#{Side := UpdatedSide};
handle_io_read({get_line, latin1, _Prompt}, Side, From, ReplyAs, State) ->
    %%
    %% IF there is a complete line in the buffer
    %% THEN pop a line from the buffer and send it
    %% ELSE store the request and reply_as reference
    %%
    #{
        Side := #side{reader = From, buffer = Buffer} = C
    } = State,

    UpdatedSide =
        case binary:split(Buffer, <<"\n">>) of
            [Line, Rest] ->
                From ! {io_reply, ReplyAs, <<Line/binary, "\n">>},
                C#side{buffer = Rest};
            [Buffer] ->
                C#side{waiting_read = {get_line, latin1}, reply_as = ReplyAs}
        end,
    State#{Side := UpdatedSide}.

handle_io_write({put_chars, latin1, Chars}, OtherSide, From, ReplyAs, State) ->
    %%
    %% 1. Put the chars into the other clients buffer.
    %%
    %% 2. IF the other client has a waiting get_line request
    %%    AND there is a complete line in the buffer
    %%    THEN pop a line from the buffer and send it to the other client.
    %%
    %% 3. Reply 'ok' immediately to the sender
    %%
    #{
        OtherSide := #side{
            reader = Pid,
            waiting_read = WaitingRead,
            reply_as = Ref,
            buffer = Buffer
        } = C
    } = State,

    Buffer1 = <<Buffer/binary, Chars/binary>>,
    UpdatedSide =
        case WaitingRead of
            undefined ->
                C#side{buffer = Buffer1};
            {get_line, latin1} ->
                case binary:split(Buffer1, <<"\n">>) of
                    [Line, Rest] ->
                        Pid ! {io_reply, Ref, <<Line/binary, "\n">>},
                        C#side{waiting_read = undefined, reply_as = undefined, buffer = Rest};
                    [Buffer1] ->
                        C#side{buffer = Buffer1}
                end;
            {get_chars, latin1, N} ->
                case Buffer1 of
                    <<Bytes:N/binary, Rest/binary>> ->
                        Pid ! {io_reply, Ref, Bytes},
                        C#side{waiting_read = undefined, reply_as = undefined, buffer = Rest};
                    <<Buffer1/binary>> ->
                        C#side{buffer = Buffer1}
                end
            %%
            %% TODO: Support get_until
            %%
        end,
    From ! {io_reply, ReplyAs, ok},
    State#{OtherSide := UpdatedSide}.

other(client_a) -> client_b;
other(client_b) -> client_a.
