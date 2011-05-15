%%% Copyright 2010-2011 Manolis Papadakis <manopapad@gmail.com>,
%%%                     Eirini Arvaniti <eirinibob@gmail.com>
%%%                 and Kostis Sagonas <kostis@cs.ntua.gr>
%%%
%%% This file is part of PropEr.
%%%
%%% PropEr is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% PropEr is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with PropEr.  If not, see <http://www.gnu.org/licenses/>.

%%% @copyright 2010-2011 Manolis Papadakis <manopapad@gmail.com>,
%%%                      Eirini Arvaniti <eirinibob@gmail.com>
%%%                  and Kostis Sagonas <kostis@cs.ntua.gr>
%%% @version {@version}
%%% @author Eirini Arvaniti <eirinibob@gmail.com>

%%% @doc This module contains functions for testing stateful systems whose
%%% side-effects are specified via an abstract state machine. Given a callback
%%% module implementing the state machine, PropEr can generate random
%%% symbolic command sequences subject to the constraints of the specification.
%%% These command sequences model the operations in the system under test (SUT).
%%% As a next step, symbolic command sequences are evaluated in order to check
%%% that the system behaves as expected. Upon failure, the shrinking mechanism
%%% attempts to find a minimal command sequence provoking the same error.
%%%
%%% When including the <code>"proper/include/proper.hrl"</code> header file,
%%% all <a href="#index">API functions </a> of {@module} are automatically
%%% imported, unless `PROPER_NO_IMPORTS' is defined.
%%%
%%% == Command representation ==
%%% The testcases generated for stateful systems are lists of symbolic API
%%% calls. Symbolic representation makes failing testcases easier to shrink
%%% and also easier to read and understand.
%%% Since the results of the symbolic calls are not known at generation time,
%%% we use symbolic variables ({@type symb_var()}) to refer to them.
%%% A command ({@type command()}) is a symbolic term, used to bind a symbolic
%%% variable to the result of a symbolic call. For example:
%%%
%%% ```[{set, {var,1}, {call,erlang,put,[a,42]}},
%%%     {set, {var,2}, {call,erlang,erase,[a]}},
%%%     {set, {var,3}, {call,erlang,put,[b,{var,2}]}}]'''
%%%
%%% is a command sequence that could be used to test the process dictionary.
%%% Initially, the pair `{a,42}' is stored in the process dictionary. Then, the
%%% key `a' is deleted. Finally, a new pair `{b,{var,2}}' is stored. `{var,2}'
%%% is a symbolic variable bound to the result of the `erlang:erase/1' call.
%%% The expected result is that `{b,42}' will be finally stored in the process
%%% dictionary.
%%%
%%% == Testcase state ==
%%% In order to be able to test impure code, we need  a way to track its
%%% internal state (at least the useful part of it). To this end,
%%% we use an abstract state machine (asm) as a  model of the internal state of
%%% the SUT. When referring to <i>testcase state</i>, we mean the state of the
%%% asm. Testcase state can be either symbolic or dynamic:
%%% <ul>
%%% <li>During command generation, we use symbolic variables to bind the
%%% results of symbolic calls. Therefore, the state of the asm might
%%% (and usually does) contain symbolic variables and/or symbolic calls, which
%%% are necessary to operate on symbolic variables. Thus, we refer to it as
%%% symbolic state. For example, assuming that the internal state of the
%%% process dictionary is modelled as a proplist, the testcase state after
%%% generating the previous command sequence will be `[{b,{var,2}}]'.</li>
%%% <li>During command execution, symbolic calls are evaluated and symbolic
%%% variables are replaced by their corresponding real values. Now we refer to
%%% the state as dynamic state. After running the previous command sequence,
%%% the testcase state will be `[{b,42}]'.</li>
%%% </ul>
%%%
%%% == Callback functions ==
%%% The following functions must be exported from the callback module
%%% implementing the abstract state machine:
%%% <ul>
%%% <li> `initial_state() ::' {@type symbolic_state()}
%%%   <p>Specifies the symbolic initial state of the state machine. This state
%%%   will be evaluated at command execution time to produce the actual initial
%%%   state. The function is not only called at command generation time, but
%%%   also in order to initialize the state every time the command sequence is
%%%   run (i.e. during normal execution, while shrinking and when checking a
%%%   counterexample). For this reason, it should be deterministic.</p></li>
%%% <li> `command(S::'{@type symbolic_state()}`) ::' {@type proper_types:type()}
%%%   <p>Generates a symbolic call to be included in the command sequence,
%%%   given the current state `S' of the abstract state machine. However,
%%%   before the call is actually included, a precondition is checked.</p></li>
%%% <li> `precondition(S::'{@type symbolic_state()}`,
%%%                    Call::'{@type symb_call()}`) :: boolean()'
%%%   <p>Specifies the precondition that should hold so that `Call' can be
%%%   included in the command sequence, given the current state `S' of the
%%%   abstract state machine. In case precondition doesn't hold, a new call is
%%%   chosen using the `command/1' generator. If preconditions are very strict,
%%%   it will take a lot of tries for PropEr to randomly choose a valid command.
%%%   Testing will be stopped in case the 'constraint_tries' limit is reached
%%%   (see the 'Options' section).</p></li>
%%% <li> `postcondition(S::'{@type dynamic_state()}`,
%%%                     Call::'{@type symbolic_call()}`,
%%%                     Res::term()) :: boolean()'
%%%   <p>Specifies the postcondition that should hold about the result `Res' of
%%%   performing `Call', given the dynamic state `S' of the abstract state
%%%   machine prior to command execution. This function is called during
%%%   runtime, this is why the state is dynamic.</p></li>
%%% <li> `next_state(S::'{@type symbolic_state()}`|'{@type dynamic_state()}`,
%%%                  Res::term(),
%%%                  Call::'{@type symbolic_call()}`) ::'
%%%        {@type symbolic_state()}
%%%   <p>Specifies the next state of the abstract state machine, given the
%%%   current state `S', the symbolic `Call' chosen and its result `Res'. This
%%%   function is called both at command generation and command execution time
%%%   in order to update the testcase state, therefore the state `S' and the
%%%   result `Res' can be either symbolic or dynamic.</p></li>
%%% </ul>
%%%
%%% == Property for testing stateful systems ==
%%% This is an example of a property to test the process dictionary:
%%%
%%% ```prop_pdict() ->
%%%       ?FORALL(Cmds, commands(?MODULE),
%%%        begin
%%%         {H,S,Res} = run_commands(?MODULE, Cmds),
%%%         cleanup(),
%%%         ?WHENFAIL(io:format("History: ~w\nState: ~w\nRes: ~w\n",
%%%	                        [H,S,Res]),
%%%		      aggregate(command_names(Cmds), Res =:= ok))
%%%        end).'''
%%%
%%% == Parallel testing ==
%%% After ensuring that a system's behaviour can be described via an abstract
%%% state machine when commands are executed sequentially, it is possible to
%%% move to parallel testing. The same state machine can be used to generate
%%% command sequences that will be executed concurrently to test for race
%%% conditions. A parallel testcase ({@type parallel_test_case()}) consists of
%%% a sequential part and a list of concurrent tasks. The sequential part is
%%% a command list that is run first to put the system in a random state. The
%%% concurrent tasks are also command lists and they are executed in parallel,
%%% each of them in a separate process. After running a parallel testcase,
%%% PropEr uses the state machine specification to check if the results
%%% observed could have been produced by a possible serialization of the
%%% concurrent tasks. If no such serialization is possible, then an atomicity
%%% violation is detected. Properties for parallel testing are very similar to
%%% those used for sequential testing.
%%%
%%% ```prop_parallel_testing() ->
%%%       ?FORALL(Testcase, parallel_commands(?MODULE),
%%%        begin
%%%         {Seq,Par,Res} = run_parallel_commands(?MODULE, Testcase),
%%%         cleanup(),
%%%         ?WHENFAIL(io:format("Sequential: ~w\nParallel: ~w\nRes: ~w\n",
%%%	                        [Seq,Par,Res]),
%%%		      Res =:= ok)
%%%        end).'''
%%% @end

-module(proper_statem).
-export([commands/1, commands/2, parallel_commands/1, parallel_commands/2,
	 more_commands/2]).
-export([run_commands/2, run_commands/3, run_parallel_commands/2,
	 run_parallel_commands/3]).
-export([state_after/2, command_names/1, zip/2]).

-include("proper_internal.hrl").

-define(WORKERS, 2).
-define(LIMIT, 12).


%% -----------------------------------------------------------------------------
%% Exported only for testing purposes
%% -----------------------------------------------------------------------------

-export([index/2, all_insertions/3, insert_all/2]).
-export([is_valid/4, args_defined/2]).
-export([get_next/6, mk_first_comb/3, fix_gen/8, mk_dict/2]).
-export([is_parallel/4, execute/4, check/7, run_sequential/5,
	 get_initial_state/2, safe_eval_init/2]).


%% -----------------------------------------------------------------------------
%% Type declarations
%% -----------------------------------------------------------------------------

-type symbolic_state()     :: term().
-type dynamic_state()      :: term().
-type symb_var()           :: {'var',pos_integer()}.
-type symb_call()          :: {'call',mod_name(),fun_name(),[term()]}.
-type command()            :: {'init',symbolic_state()}
		              | {'set',symb_var(),symb_call()}.
-type command_list()       :: [command()].
-type parallel_test_case() :: {command_list(),[command_list()]}.
-type command_history()    :: [{command(),term()}].
-type history()            :: [{dynamic_state(),term()}].
-type statem_result() :: 'ok'
			 | 'initialization_error'
			 | {'precondition',  boolean() | proper:exception()}
			 | {'postcondition', boolean() | proper:exception()}
			 | proper:exception()
			 | 'no_possible_interleaving'.

-type combination() :: [{pos_integer(),[pos_integer()]}].
-type lookup()      :: orddict:orddict().

-export_type([symb_var/0, symb_call/0, statem_result/0]).


%% -----------------------------------------------------------------------------
%% Sequential command generation
%% -----------------------------------------------------------------------------

%% @spec commands(mod_name()) -> proper_types:type()
%% @doc A special PropEr type which generates random command sequences,
%% according to an absract state machine specification. The function takes as
%% input the name of a callback module, which contains the state machine
%% specification. The initial state is computed by `Mod:initial_state/0'.

-spec commands(mod_name()) -> proper_types:type().
commands(Mod) ->
    ?LET(InitialState, ?LAZY(Mod:initial_state()),
	 ?SUCHTHAT(
	    Cmds,
	    ?LET(List,
		 ?SIZED(Size,
			proper_types:noshrink(
			  commands(Size, Mod, InitialState, 1))),
	       proper_types:shrink_list(List)),
	    is_valid(Mod, InitialState, Cmds, []))).

%% @spec commands(mod_name(), symbolic_state()) -> proper_types:type()
%% @doc Similar to {@link commands/1}, but generated command sequences always
%% start at a given state. In this case, the first command is always
%% `{init,InitialState}' and is used to correctly initialize the state
%% every time the command sequence is run (i.e. during normal execution,
%% while shrinking and when checking a counterexample). In this case,
%% `Mod:initial_state/0' is never called.

-spec commands(mod_name(), symbolic_state()) -> proper_types:type().
commands(Mod, InitialState) ->
    ?SUCHTHAT(
       Cmds,
       ?LET(CmdTail,
	    ?LET(List,
		 ?SIZED(Size,
			proper_types:noshrink(
			  commands(Size, Mod, InitialState, 1))),
	       proper_types:shrink_list(List)),
	  [{init,InitialState}|CmdTail]),
       is_valid(Mod, InitialState, Cmds, [])).

-spec commands(size(), mod_name(), symbolic_state(), pos_integer()) ->
         proper_types:type().
commands(Size, Mod, State, Count) ->
    ?LAZY(
       proper_types:frequency(
	 [{1, []},
	  {Size, ?LET(Call,
		      ?SUCHTHAT(X, Mod:command(State),
				Mod:precondition(State, X)),
		      begin
			  Var = {var,Count},
			  NextState = Mod:next_state(State, Var, Call),
			  ?LET(
			     Cmds,
			     commands(Size-1, Mod, NextState, Count+1),
			     [{set,Var,Call}|Cmds])
		      end)}])).

-spec more_commands(pos_integer(), proper_types:type()) -> proper_types:type().
more_commands(N, Type) ->
    ?SIZED(Size, proper_types:resize(Size * N, Type)).


%% -----------------------------------------------------------------------------
%% Parallel command generation
%% -----------------------------------------------------------------------------

%% @spec parallel_commands(mod_name()) -> proper_types:type()
%% @doc A special PropEr type which generates parallel testcases,
%% according to an absract state machine specification. The function takes as
%% input the name of a callback module, which contains the state machine
%% specification. The initial state is computed by `Mod:initial_state/0'.

-spec parallel_commands(mod_name()) -> proper_types:type().
parallel_commands(Mod) ->
    ?LET({NewSeq, NewPar},
	 ?LET({Seq, Par},
	      proper_types:noshrink(parallel_gen_type(Mod)),
	      parallel_shrink_type(Mod, Seq, Par)),
	 move_shrinker(NewSeq, NewPar, ?WORKERS)).

%% @spec parallel_commands(mod_name(), symbolic_state()) -> proper_types:type()
%% @doc Similar to {@link parallel_commands/1}, but generated command sequences
%% always start at a given state.

-spec parallel_commands(mod_name(), symbolic_state()) -> proper_types:type().
parallel_commands(Mod, InitialState) ->
    ?LET({NewSeq, NewPar},
	 ?LET({Seq, Par},
	      proper_types:noshrink(parallel_gen_type(Mod, InitialState)),
	      parallel_shrink_type(Mod, Seq, Par)),
	 move_shrinker(NewSeq, NewPar, ?WORKERS)).

-spec move_shrinker(command_list(), [command_list()], pos_integer()) ->
	 proper_types:type().
move_shrinker(Seq, Par, 1) ->
    ?SHRINK({Seq, Par},
	    [{Seq ++ Slice, remove_slice(1, Slice, Par)}
	     ||	Slice <- get_slices(lists:nth(1, Par))]);
move_shrinker(Seq, Par, I) ->
    ?LET({NewSeq, NewPar},
	 ?SHRINK({Seq, Par},
		 [{Seq ++ Slice, remove_slice(I, Slice, Par)}
		  || Slice <- get_slices(lists:nth(I, Par))]),
	 move_shrinker(NewSeq, NewPar, I-1)).

-spec parallel_shrink_type(mod_name(), command_list(), [command_list()]) ->
	 proper_types:type().
parallel_shrink_type(Mod, [{init,I} = Init|Seq], Parallel) ->
    ?SUCHTHAT({Seq1, Parallel1},
	      ?LET(ParInstances,
		   [proper_types:shrink_list(P) || P <- Parallel],
		   ?LET(SeqInstance,
			proper_types:shrink_list(Seq),
			{[Init|SeqInstance], ParInstances})),
	      lists:all(
		fun(P) -> is_valid(Mod, I, Seq1 ++ P, []) end,
		Parallel1));
parallel_shrink_type(Mod, Seq, Parallel) ->
    I= Mod:initial_state(),
    ?SUCHTHAT({Seq1, Parallel1},
	      ?LET(ParInstances,
		   [proper_types:shrink_list(P) || P <- Parallel],
		   ?LET(SeqInstance,
			proper_types:shrink_list(Seq),
			{SeqInstance, ParInstances})),
	      lists:all(
		fun(P) -> is_valid(Mod, I, Seq1 ++ P, []) end,
		Parallel1)).

-spec parallel_gen_type(mod_name()) -> proper_types:type().
parallel_gen_type(Mod) ->
    ?LET(Seq,
	 commands(Mod),
	 mk_parallel_testcase(Mod, Seq)).

-spec parallel_gen_type(mod_name(), symbolic_state()) -> proper_types:type().
parallel_gen_type(Mod, InitialState) ->
    ?LET(Seq,
	 commands(Mod, InitialState),
	 mk_parallel_testcase(Mod, Seq)).

-spec mk_parallel_testcase(mod_name(), command_list()) -> proper_types:type().
mk_parallel_testcase(Mod, Seq) ->
    {State, Env} = state_env_after(Mod, Seq),
    Count = case Env of
		[]          -> 1;
		[{var,N}|_] -> N + 1
	    end,
    ?LET(Parallel,
	 ?SUCHTHAT(C, commands(?LIMIT, Mod, State, Count),
		   length(C) > ?WORKERS),
	 begin
	     LenPar = length(Parallel),
	     Len = LenPar div ?WORKERS,
	     Comb = mk_first_comb(LenPar, Len, ?WORKERS),
	     LookUp = orddict:from_list(mk_dict(Parallel, 1)),
	     {Seq, fix_gen(LenPar, Len, Comb, LookUp, Mod,
			   State, Env, ?WORKERS)}
	 end).

-spec fix_gen(pos_integer(), non_neg_integer(), combination() | 'done',
	      lookup(), mod_name(), symbolic_state(), [symb_var()],
	      pos_integer()) -> [command_list()].
fix_gen(_, 0, done, _, _, _, _, _) ->
    exit(error);   %% not supposed to reach here
fix_gen(MaxIndex, Len, done, LookUp, Mod, State, Env, W) ->
    Comb = mk_first_comb(MaxIndex, Len-1, W),
    case Len of
	1 -> io:format("f");
	_ -> ok
    end,
    fix_gen(MaxIndex, Len-1, Comb , LookUp, Mod, State, Env, W);
fix_gen(MaxIndex, Len, Comb, LookUp, Mod, State, Env, W) ->
    Cs = get_commands(Comb, LookUp),
    case is_parallel(Cs, Mod, State, Env) of
	true ->
	    Cs;
	false ->
	    C1 = proplists:get_value(1, Comb),
	    C2 = proplists:get_value(2, Comb),
	    Next = get_next(Comb, Len, MaxIndex, lists:sort(C1 ++ C2), W, 2),
	    fix_gen(MaxIndex, Len, Next, LookUp, Mod, State, Env, W)
    end.

%% @private
-spec is_parallel([command_list()], mod_name(), symbolic_state(),
		  [symb_var()]) -> boolean().
is_parallel(Cs, Mod, State, Env) ->
    %% TODO: produce possible interleavings in a lazy way
    Cmds = Cs ++ possible_interleavings(Cs),
    lists:all(fun(C) -> is_valid(Mod, State, C, Env) end, Cmds).


%% -----------------------------------------------------------------------------
%% Sequential command execution
%% -----------------------------------------------------------------------------

%% @spec run_commands(mod_name(), command_list()) ->
%%          {history(),dynamic_state(),statem_result()}
%% @doc Evaluates a given symbolic command sequence `Cmds' according to the
%%  state machine specified in `Mod'. The result is a triple of the form<br/>
%%  `{History, DynamicState, Result}', where:
%% <ul>
%% <li>`History' contains the execution history of all commands that were
%%   executed without raising an exception. It contains tuples of the form
%%   {{@type dynamic_state()}, {@type term()}}, specifying the state prior to
%%   command execution and the actual result of the command.</li>
%% <li>`DynamicState' contains the state of the abstract state machine at
%%   the moment when execution stopped.</li>
%% <li>`Result' specifies the outcome of command execution.</li>
%% </ul>

-spec run_commands(mod_name(), command_list()) ->
         {history(),dynamic_state(),statem_result()}.
run_commands(Mod, Cmds) ->
    run_commands(Mod, Cmds, []).

%% @spec run_commands(mod_name(), command_list(), proper_symb:var_values()) ->
%%          {history(),dynamic_state(),statem_result()}
%% @doc  Similar to {@link run_commands/2}, but also accepts an environment,
%% used for symbolic variable evaluation during command execution. The
%% environment consists of `{Key::atom(), Value::term()}' pairs. Keys may be
%% used in symbolic variables (i.e. `{var,Key}') whithin the command sequence
%% `Cmds'. These symbolic variables will be replaced by their corresponding
%% `Value' during command execution.

-spec run_commands(mod_name(), command_list(), proper_symb:var_values()) ->
         {history(),dynamic_state(),statem_result()}.
run_commands(Mod, Cmds, Env) ->
    InitialState = get_initial_state(Mod, Cmds),
    case safe_eval_init(Env, InitialState) of
	{ok,DynState} ->
	    do_run_command(Cmds, Env, Mod, [], DynState);
	{error,Reason} ->
	    {[], [], Reason}
    end.

%% @private
-spec safe_eval_init(proper_symb:var_values(), symbolic_state()) ->
         {'ok',dynamic_state()} | {'error',statem_result()}.
safe_eval_init(Env, SymbState) ->
    try proper_symb:eval(Env, SymbState) of
	DynState ->
	    {ok,DynState}
    catch
	_Exception:_Reason ->
	    {error,initialization_error}
    end.

-spec do_run_command(command_list(), proper_symb:var_values(), mod_name(),
		     history(), dynamic_state()) ->
         {history(),dynamic_state(),statem_result()}.
do_run_command(Cmds, Env, Mod, History, State) ->
    case Cmds of
	[] ->
	    {lists:reverse(History), State, ok};
	[{init,_S}|Rest] ->
	    do_run_command(Rest, Env, Mod, History, State);
	[{set, {var,V}, {call,M,F,A}}|Rest] ->
	    M2 = proper_symb:eval(Env, M),
	    F2 = proper_symb:eval(Env, F),
	    A2 = proper_symb:eval(Env, A),
	    Call = {call,M2,F2,A2},
	    case check_precondition(Mod, State, Call) of
		true ->
		    case safe_apply(M2, F2, A2) of
			{ok,Res} ->
			    Env2 = [{V,Res}|Env],
			    State2 =
				proper_symb:eval(
				  Env2, Mod:next_state(State, Res, Call)),
			    History2 = [{State,Res}|History],
			    case check_postcondition(Mod, State, Call, Res)
			    of
				true ->
				    do_run_command(Rest, Env2, Mod,
						   History2, State2);
				false ->
				    {lists:reverse(History2), State2,
				     {postcondition,false}};
				{exception,_,_,_} = Exception ->
				    {lists:reverse(History2), State2,
				     {postcondition,Exception}}
			    end;
			{error,Exception} ->
			    {lists:reverse(History), State, Exception}
		    end;
		false ->
		    {lists:reverse(History), State, {precondition,false}};
		{exception,_,_,_} = Exception ->
		    {lists:reverse(History), State, {precondition,Exception}}
	    end
    end.

-spec check_precondition(mod_name(), dynamic_state(), symb_call()) ->
         boolean() | proper:exception().
check_precondition(Mod, State, Call) ->
    try Mod:precondition(State, Call)
    catch
	Kind:Reason ->
	    {exception,Kind,Reason,erlang:get_stacktrace()}
    end.

-spec check_postcondition(mod_name(), dynamic_state(), symb_call(), term()) ->
         boolean() | proper:exception().
check_postcondition(Mod, State, Call, Res) ->
    try Mod:postcondition(State, Call, Res)
    catch
	Kind:Reason ->
	    {exception,Kind,Reason,erlang:get_stacktrace()}
    end.

-spec safe_apply(mod_name(), fun_name(), [term()]) ->
         {'ok', term()} | {'error', proper:exception()}.
safe_apply(M, F, A) ->
    try apply(M, F, A) of
	Result -> {ok, Result}
    catch
	Kind:Reason ->
	    {error, {exception,Kind,Reason,erlang:get_stacktrace()}}
    end.


%% -----------------------------------------------------------------------------
%% Parallel command execution
%% -----------------------------------------------------------------------------

%% @spec run_parallel_commands(mod_name(), parallel_test_case()) ->
%%	    {history(),[command_history()],statem_result()}
%% @doc Runs a given parallel testcase according to the state machine
%% specified in `Mod'. The result is a triple of the form<br/>
%% `@{Sequential_history, Parallel_history, Result@}', where:
%% <ul>
%% <li>`Sequential_history' contains the execution history of the
%%   sequential prefix.</li>
%% <li>`Parallel_history' contains the execution history of each of the
%%   concurrent tasks.</li>
%% <li>`Result' specifies the outcome of the attemp to serialize command
%%   execution, based on the results observed. It can be one of the following:
%%   <ul><li> `ok' </li><li> `no_possible_interleaving' </li></ul> </li>
%% </ul>

-spec run_parallel_commands(mod_name(), parallel_test_case()) ->
	 {history(),[command_history()],statem_result()}.
run_parallel_commands(Mod, {_Sequential, _Parallel} = Testcase) ->
    run_parallel_commands(Mod, Testcase, []).

%% @spec run_parallel_commands(mod_name(), Testcase::parallel_test_case(),
%%			       proper_symb:var_values()) ->
%%	    {history(),[command_history()],statem_result()}
%% @doc Similar to {@link run_parallel_commands/2}, but also accepts an
%% environment used for symbolic variable evaluation, exactly as described in
%% {@link run_commands/3}.

-spec run_parallel_commands(mod_name(), parallel_test_case(),
			    proper_symb:var_values()) ->
	 {history(),[command_history()],statem_result()}.
run_parallel_commands(Mod, {Sequential, Parallel}, Env) ->
    InitialState = get_initial_state(Mod, Sequential),
    case safe_eval_init(Env, InitialState) of
	{ok, DynState} ->
	    {{Seq_history, State, ok}, Env1} =
		run_sequential(Sequential, Env, Mod, [], DynState),
	    F = fun(T) -> execute(T, Env1, Mod, []) end,
	    Parallel_history = pmap(F, Parallel),
	    case check(Mod, State, Env1, Env1, [],
		       Parallel_history, []) of
		true ->
		    {Seq_history, Parallel_history, ok};
		false ->
		    {Seq_history, Parallel_history,
		     no_possible_interleaving}
	    end;
	{error, Reason} ->
	    {[], [], Reason}
    end.

-spec pmap(fun((command_list()) -> command_history()), [command_list()]) ->
         [command_history()].
pmap(F, L) ->
    await(lists:reverse(spawn_jobs(F,L))).

-spec spawn_jobs(fun((command_list()) -> command_history()),
		 [command_list()]) -> [pid()].
spawn_jobs(F, L) ->
    Parent = self(),
    [proper:spawn_link_migrate(fun() -> Parent ! {self(),catch {ok,F(X)}} end)
     || X <- L].

-spec await([pid()]) -> [command_history()].
await(Pids) ->
    await_tr(Pids, []).

-spec await_tr([pid()], [command_history()]) -> [command_history()].
await_tr([], Accum) -> Accum;
await_tr([H|T], Accum) ->
    receive
	{H, {ok, Res}} -> await_tr(T, [Res|Accum]);
	{H, {'EXIT',_} = Err} ->
	    _ = [exit(Pid,kill) || Pid <- T],
	    _ = [receive {P,_} -> d_ after 0 -> i_ end || P <- T],
	    erlang:error(Err)
    end.

%% @private
-spec check(mod_name(), dynamic_state(), proper_symb:var_values(),
	    proper_symb:var_values(), [command_history()], [command_history()],
	    command_history()) -> boolean().
check(_Mod, _State, _OldEnv, _Env, [], [], _Accum) ->
    true;
check(_Mod, _State, Env, Env, _Tried, [], _Accum) ->
    false;
check(Mod, State, _OldEnv, Env, Tried, [], Accum) ->
    check(Mod, State, Env, Env, [], Tried, Accum);
check(Mod, State, OldEnv, Env, Tried, [P|Rest], Accum) ->
    case P of
	[] ->
	    check(Mod, State, OldEnv, Env, Tried, Rest, Accum);
	[H|Tail] ->
	    {{set, {var, N1}, {call, M1, F1, A1}}, Res1} = H,
	    M1_ = proper_symb:eval(Env, M1),
	    F1_ = proper_symb:eval(Env, F1),
	    A1_ = proper_symb:eval(Env, A1),
	    Call1 = {call, M1_, F1_, A1_},
	    case Mod:postcondition(State, Call1, Res1) of
		true ->
		    Env2 = [{N1, Res1}|Env],
		    NextState = proper_symb:eval(
				  Env2,
				  Mod:next_state(State, Res1, Call1)),
		    check(Mod, NextState, OldEnv, Env2, [Tail|Tried],
			  Rest, [H|Accum]) orelse
			check(Mod, State, OldEnv, Env, [P|Tried], Rest, Accum);
		false ->
		    check(Mod, State, OldEnv, Env, [P|Tried], Rest, Accum)
	    end
    end.

%% @private
-spec run_sequential(command_list(), proper_symb:var_values(), mod_name(),
		     history(), dynamic_state()) ->
       {{history(),dynamic_state(),statem_result()}, proper_symb:var_values()}.
run_sequential(Cmds, Env, Mod, History, State) ->
    case Cmds of
	[] ->
	    {{lists:reverse(History), State, ok}, Env};
	[{init, _S}|Rest] ->
	    run_sequential(Rest, Env, Mod, History, State);
	[{set, {var,V}, {call,M,F,A}}|Rest] ->
	    M2 = proper_symb:eval(Env, M),
	    F2 = proper_symb:eval(Env, F),
	    A2 = proper_symb:eval(Env, A),
	    Call = {call, M2, F2, A2},
	    true = Mod:precondition(State, Call),
	    Res = apply(M2, F2, A2),
	    true = Mod:postcondition(State, Call, Res),
	    Env2 = [{V,Res}|Env],
	    State2 = proper_symb:eval(Env2, Mod:next_state(State, Res, Call)),
	    History2 = [{State,Res}|History],
	    run_sequential(Rest, Env2, Mod, History2, State2)
    end.

%% @private
-spec execute(command_list(), proper_symb:var_values(), mod_name(),
	      command_history()) -> command_history().
execute(Cmds, Env, Mod, History) ->
    case Cmds of
	[] ->
	    lists:reverse(History);
	[{set, {var,V}, {call,M,F,A}} = Cmd|Rest] ->
	    M2 = proper_symb:eval(Env, M),
	    F2 = proper_symb:eval(Env, F),
	    A2 = proper_symb:eval(Env, A),
	    Res = apply(M2, F2, A2),
	    Env2 = [{V,Res}|Env],
	    History2 = [{Cmd,Res}|History],
	    execute(Rest, Env2, Mod, History2)
    end.


%% -----------------------------------------------------------------------------
%% Utility functions
%% -----------------------------------------------------------------------------

%% @spec command_names(command_list()) -> [mfa()]
%% @doc Extracts the names of the commands from a given command sequence, in
%% the form of MFAs. It is useful in combination with functions such as
%% {@link proper:aggregate/2} in order to collect statistics about command
%% execution.

-spec command_names(command_list()) -> [mfa()].
command_names(Cmds) ->
    [{M, F, length(Args)} || {set, _Var, {call,M,F,Args}} <- Cmds].

%% @spec state_after(mod_name(), command_list()) -> symbolic_state()
%% @doc Returns the symbolic state after running a given command sequence,
%% according to the state machine specification found in `Mod'. The commands
%% are not actually executed.

-spec state_after(mod_name(), command_list()) -> symbolic_state().
state_after(Mod, Cmds) ->
    element(1, state_env_after(Mod, Cmds)).

-spec state_env_after(mod_name(), command_list()) ->
         {symbolic_state(), [symb_var()]}.
state_env_after(Mod, Cmds) ->
    lists:foldl(fun({init,S}, _) ->
			{S, []};
		   ({set,Var,Call}, {S,Vars}) ->
			{Mod:next_state(S, Var, Call), [Var|Vars]}
		end,
		{get_initial_state(Mod, Cmds), []},
		Cmds).

%% @spec zip([A], [B]) -> [{A,B}]
%% @doc Behaves like `lists:zip/2', but the input lists do no not necessarily
%% have equal length. Zipping stops when the shortest list stops. This is
%% useful for zipping a command sequence with its (failing) execution history.

-spec zip([A], [B]) -> [{A,B}].
zip(X, Y) ->
    zip(X, Y, []).

-spec zip([A], [B], [{A,B}]) -> [{A,B}].
zip([], _, Accum) -> lists:reverse(Accum);
zip(_, [], Accum) -> lists:reverse(Accum);
zip([X|Tail1], [Y|Tail2], Accum) ->
    zip(Tail1, Tail2, [{X,Y}|Accum]).

%% @private
-spec is_valid(mod_name(), symbolic_state(), command_list(), [symb_var()]) ->
         boolean().
is_valid(_Mod, _State, [], _Env) -> true;
is_valid(Mod, _State, [{init,S}|Cmds], _Env) ->
    is_valid(Mod, S, Cmds, _Env);
is_valid(Mod, State, [{set,Var,{call,_M,_F,A}=Call}|Cmds], Env) ->
    args_defined(A, Env) andalso Mod:precondition(State, Call)
	andalso is_valid(Mod, Mod:next_state(State, Var, Call),
			 Cmds, [Var|Env]).

%% @private
-spec args_defined([term()], [symb_var()]) -> boolean().
args_defined(List, Env) ->
   lists:all(fun (A) -> arg_defined(A, Env) end, List).

-spec arg_defined(term(), [symb_var()]) -> boolean().
arg_defined({var,I} = V, Env) when is_integer(I) ->
    lists:member(V, Env);
arg_defined(Tuple, Env) when is_tuple(Tuple) ->
    args_defined(tuple_to_list(Tuple), Env);
arg_defined(List, Env) when is_list(List) ->
    args_defined(List, Env);
arg_defined(_, _) ->
    true.

%% @private
-spec get_initial_state(mod_name(), command_list()) -> symbolic_state().
get_initial_state(_, [{init,S}|_]) -> S;
get_initial_state(Mod, Cmds) when is_list(Cmds) ->
    Mod:initial_state().

%% @private
-spec possible_interleavings([command_list()]) -> [command_list()].
possible_interleavings([P1,P2]) ->
    insert_all(P1, P2);
possible_interleavings([P1|Rest]) ->
    [I || L <- possible_interleavings(Rest),
	  I <- insert_all(P1, L)].

%% Returns all possible insertions of the elements of the first list,
%% preserving their order, inside the second list, i.e. all possible
%% command interleavings between two parallel processes

%% @private
-spec insert_all([term()], [term()]) -> [[term()]].
insert_all([], List) ->
    [List];
insert_all([X], List) ->
    all_insertions(X, length(List) + 1, List);

insert_all([X|[Y|Rest]], List) ->
    [L2 || L1 <- insert_all([Y|Rest], List),
	   L2 <- all_insertions(X,index(Y,L1),L1)].

%% @private
-spec all_insertions(term(), pos_integer(), [term()]) -> [[term()]].
all_insertions(X, Limit, List) ->
    all_insertions_tr(X, Limit, 0, [], List, []).

-spec all_insertions_tr(term(), pos_integer(), non_neg_integer(),
			[term()], [term()], [[term()]]) -> [[term()]].
all_insertions_tr(X, Limit, LengthFront, Front, [], Acc) ->
    case LengthFront < Limit of
	true ->
	    [Front ++ [X] | Acc];
	false ->
	    Acc
    end;
all_insertions_tr(X, Limit, LengthFront, Front, Back = [BackHead|BackTail],
		  Acc) ->
    case LengthFront < Limit of
	true ->
	    all_insertions_tr(X, Limit, LengthFront+1, Front ++ [BackHead],
			      BackTail, [Front ++ [X] ++ Back | Acc]);
	false -> Acc
    end.

%% @private
-spec index(term(), [term(),...]) -> pos_integer().
index(X, List) ->
    index(X, List, 1).

-spec index(term(), [term(),...], pos_integer()) -> pos_integer().
index(X, [X|_], N) -> N;
index(X, [_|Rest], N) -> index(X, Rest, N+1).

%% @private
-spec mk_dict(command_list(), pos_integer()) -> [{pos_integer(), command()}].
mk_dict([], _)           -> [];
mk_dict([{init,_}|T], N) -> mk_dict(T, N);
mk_dict([H|T], N)        -> [{N,H}|mk_dict(T, N+1)].

%% @private
-spec mk_first_comb(pos_integer(), non_neg_integer(), pos_integer()) ->
         combination().
mk_first_comb(N, Len, W) ->
    mk_first_comb_tr(1, N, Len, [], W).

-spec mk_first_comb_tr(pos_integer(), pos_integer(), non_neg_integer(),
		       combination(), pos_integer()) -> combination().
mk_first_comb_tr(Start, N, _Len, Accum, 1) ->
    [{1,lists:seq(Start, N)}|Accum];
mk_first_comb_tr(Start, N, Len, Accum, W) ->
    K = Start + Len,
    mk_first_comb_tr(K, N, Len, [{W,lists:seq(Start, K-1)}|Accum], W-1).

-spec get_commands_inner([pos_integer()], lookup()) -> command_list().
get_commands_inner(Indices, LookUp) ->
    [orddict:fetch(Index, LookUp) || Index <- Indices].

-spec get_commands(combination(), lookup()) -> [command_list()].
get_commands(PropList, LookUp) ->
    [get_commands_inner(W, LookUp) || {_, W} <- PropList].

%% @private
-spec get_next(combination(), non_neg_integer(), pos_integer(),
	       [pos_integer()], pos_integer(), pos_integer()) ->
         combination() | 'done'.
get_next(L, _Len, _MaxIndex, Available, _Workers, 1) ->
    [{1,Available}|proplists:delete(1, L)];
get_next(L, Len, MaxIndex, Available, Workers, N) ->
    C = case proplists:is_defined(N, L) of
	    true ->
		next_comb(MaxIndex, proplists:get_value(N, L), Available);
	    false ->
		lists:sublist(Available, Len)
	end,
    case C of
	done ->
	    if N =:= Workers ->
		    done;
	       N =/= Workers ->
		    C2 = proplists:get_value(N+1, L),
		    NewList = [E || {M,_}=E <- L, M > N],
		    get_next(NewList, Len, MaxIndex,
			     lists:sort(C2 ++ Available), Workers, N+1)
	    end;
	_ ->
	    get_next([{N,C}|proplists:delete(N, L)],
		     Len, MaxIndex, Available -- C, Workers, N-1)
    end.

-spec next_comb(pos_integer(), [pos_integer()], [pos_integer()]) ->
         [pos_integer()] | 'done'.
next_comb(MaxIndex, Comb, Available) ->
    Res = next_comb_tr(MaxIndex, lists:reverse(Comb), []),
    case is_well_defined(Res, Available) of
	true -> Res;
	false -> next_comb(MaxIndex, Res, Available)
    end.

-spec is_well_defined([pos_integer()] | 'done', [pos_integer()]) -> boolean().
is_well_defined(done, _) -> true;
is_well_defined(Comb, Available) ->
    lists:usort(Comb) =:= Comb andalso
	lists:all(fun(X) -> lists:member(X, Available) end, Comb).

-spec next_comb_tr(pos_integer(), [pos_integer()], [pos_integer()]) ->
         [pos_integer()] | 'done'.
next_comb_tr(_MaxIndex, [], _Acc) ->
    done;
next_comb_tr(MaxIndex, [MaxIndex | Rest], Acc) ->
    next_comb_tr(MaxIndex, Rest, [1 | Acc]);
next_comb_tr(_MaxIndex, [X | Rest], Acc) ->
    lists:reverse(Rest) ++ [X+1] ++ Acc.

-spec remove_slice(pos_integer(), command_list(), [command_list(),...]) ->
         [command_list(),...].
remove_slice(Index, Slice, List) ->
    remove_slice_tr(Index, Slice, List, [], 1).

-spec remove_slice_tr(pos_integer(), command_list(), [command_list(),...],
		      [command_list()], pos_integer()) -> [command_list(),...].
remove_slice_tr(Index, Slice, [H|T], Acc, Index) ->
    lists:reverse(Acc) ++ [H -- Slice] ++ T;
remove_slice_tr(Index, Slice, [H|T], Acc, N) ->
    remove_slice_tr(Index, Slice, T, [H|Acc], N+1).

-spec get_slices(command_list()) -> [command_list()].
get_slices(List) ->
    get_slices_tr(List, List, 1, []).

-spec get_slices_tr(command_list(), command_list(), pos_integer(),
		    [command_list()]) -> [command_list()].
get_slices_tr([], _, _, Acc) -> Acc;
get_slices_tr([_|Tail], List, N, Acc) ->
    get_slices_tr(Tail, List, N+1, [lists:sublist(List, N)|Acc]).


%% @type symbolic_state().
%% State of the abstract state machine, possibly containing symbolic variables
%% and/or symbolic calls.
%% @type dynamic_state().
%% State of the abstract state machine containing only real values, i.e. all
%% symbolic terms have been evaluated.
%% @type symb_var() = {'var',pos_integer()}.
%% Symbolic term to which we bind the result of a command.
%% @type symb_call() = {'call',mod_name(),fun_name(),[term()]}.
%% Symbolic term which will be evaluated to a function call.
%% @type command() = {'set',symb_var(),symb_call()} | {'init',symbolic_state()}.
%% Symbolic term used to bind the result of a symbolic call to a symbolic
%% variable or to initialize the state.
%% @type command_list() = [command()].
%% List of symbolic commands.
%% @type parallel_test_case() = {command_list(),[command_list()]}.
%% A parallel testcase, consisting of a sequential prefix and a list of
%% concurrent tasks.
%% @type command_history() = [{command(),term()}].
%% History of parallel command execution. Contains the commands that were
%% executed zipped with their results.
%% @type history() = [{dynamic_state(),term()}].
%% History of sequential command execution. Contains the dynamic state
%% prior to command execution and the actual result, for each command
%% that was executed without raising an exception.
%% @type statem_result() = 'ok'
%%			 | 'initialization_error'
%%			 | {'precondition',  boolean() | proper:exception()}
%%			 | {'postcondition', boolean() | proper:exception()}
%%			 | proper:exception()
%%			 | 'no_possible_interleaving'.
%% Specifies the overall result of command execution. It can be one of
%% following:
%% <ul>
%%  <li><b>ok</b>
%%  <p>All commands were successfully run and all postconditions were true.</p>
%%  </li>
%%  <li><b>initialization_error</b>
%%  <p>There was an error while evaluating the initial state.</p>
%%  </li>
%%  <li><b>postcondition</b>
%%  <p>A postcondition was false or raised an exception.</p>
%%  </li>
%%  <li><b>precondition</b>
%%  <p>A precondition was false or raised an exception.</p>
%%  </li>
%%  <li><b>exception</b>
%%  <p>An exception was raised while running a command.</p>
%%  </li>
%%  <li><b>no_possible_interleaving</b>
%%  <p>Occurs only in parallel testing and indicates an atomicity violation.</p>
%%  </li>
%% </ul>
