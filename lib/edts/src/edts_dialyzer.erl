%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc EDTS Dialyzer integration code.
%%% @end
%%% @author Thomas Järvstrand <tjarvstrand@gmail.com>
%%% @copyright
%%% Copyright 2012 Thomas Järvstrand <tjarvstrand@gmail.com>
%%%
%%% This file is part of EDTS.
%%%
%%% EDTS is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% EDTS is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with EDTS. If not, see <http://www.gnu.org/licenses/>.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =======================================================
-module(edts_dialyzer).

%%%_* Exports ==================================================================

%% API
-export([run/3]).

%%%_* Includes =================================================================
-include_lib("eunit/include/eunit.hrl").

%%%_* Defines ==================================================================

%%%_* Types ====================================================================

%%%_* API ======================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Runs dialyzer.
%%
%% Add Files to OutPlt, creating it if it doesn't exist. Then analyze OtpPlt and
%% OutPlt together.
%% @end
-spec run(Plts::filename:filename() | undefined,
          OutPlt::filename:filename(),
          Files::[filename:filename()] | all) -> ok.
%%------------------------------------------------------------------------------
run(Plts, OutPlt, Modules) ->
  LoadedFiles = % Non-otp modules
    non_otp_beam_files(code:lib_dir(), code:all_loaded()),
  ok = update_plt(LoadedFiles, OutPlt, Plts),
  Warnings = check_plt(Modules, OutPlt),
  format_warnings(filter_warnings(Modules, Warnings)).

%%%_* Internal functions =======================================================

check_plt(Modules, Plt) ->
  {ok, PltFiles} = dialyzer_plt:included_files(Plt),
  Files = beam_files_to_analyze(Modules, PltFiles),
  Opts = [{files, Files},
          {init_plt, Plt},
          {output_plt, Plt},
          {analysis_type, plt_check}],
  dialyzer:run(Opts).

beam_files_to_analyze(Modules, PltFiles) ->
  F = fun(M, Acc) -> beam_files_to_analyze_aux(M, PltFiles, Acc) end,
  lists:foldl(F, [], Modules).

beam_files_to_analyze_aux(M, PltFiles, Acc) ->
  case code:is_loaded(M) of
    false     -> Acc;
    {M, Beam} ->
      case lists:member(Beam, PltFiles) of
        true  -> [Beam|Acc];
        false -> Acc
      end
  end.

update_plt(LoadedFiles, Plts, OutPlt) ->
  case filelib:is_file(OutPlt) of
    true  -> create_plt(LoadedFiles, Plts, OutPlt);
    false ->
      {ok, OldFiles} = dialyzer_plt:included_files(OutPlt),
      case LoadedFiles -- OldFiles of
        []         -> ok;
        FilesToAdd -> add_to_plt(FilesToAdd, OutPlt)
      end,
      case OldFiles -- LoadedFiles of
        []            -> ok;
        FilesToRemove -> remove_from_plt(FilesToRemove, OutPlt)
      end,
      ok
  end.

remove_from_plt(Files, Plt) ->
  Opts = [{files, Files},
          {init_plt, Plt},
          {output_plt, Plt},
          {analysis_type, plt_remove}],
  dialyzer:run(Opts).


add_to_plt(Files, Plt) ->
  Opts = [{files, Files},
          {init_plt, Plt},
          {output_plt, Plt},
          {analysis_type, plt_add}],
  dialyzer:run(Opts).

create_plt(LoadedFiles, Plts, OutPlt) ->
  Opts = [{files, LoadedFiles},
          {output_plt, OutPlt},
          {plts, Plts},
          {analysis_type, plt_build}],
  dialyzer:run(Opts).

non_otp_beam_files(OtpLibDir, LoadedModules) ->
  F = fun({_M, Loc}, Acc) when is_list(Loc) ->
          % Loaded from file and not an otp library.
          case filename:extension(Loc) =:= ".beam" andalso
               not lists:prefix(OtpLibDir, Loc) of
            true  -> [Loc|Acc];
            false -> Acc
          end;
         (_, Acc) -> Acc
      end,
  lists:foldl(F, [], LoadedModules).


filter_warnings(Modules, Warnings) ->
  case Modules of
    all -> Warnings;
    _   ->
      Fun =
        fun({_, {F, _}, _}) ->
            Module = list_to_atom(filename:rootname(filename:basename(F))),
            lists:member(Module, Modules)
        end,
      lists:filter(Fun, Warnings)
  end.


format_warnings(Warnings) ->
  F = fun({_, {File, Line}, _} = Warning) ->
          {warning, File, Line, dialyzer:format_warning(Warning)}
      end,
  lists:map(F, Warnings).

%%%_* Unit tests ===============================================================


non_otp_beam_files_test_() ->
  {ok, Cwd} = file:get_cwd(),
  OtpDir = filename:join([Cwd, "otp", "lib"]),
  [?_assertEqual([], non_otp_beam_files(OtpDir, [{test, preloaded}])),
   ?_assertEqual([], non_otp_beam_files(OtpDir, [{test, OtpDir}])),
   ?_assertEqual([], non_otp_beam_files(OtpDir, [{test, "test"}])),
   ?_assertEqual(["test.beam"],
                 non_otp_beam_files(OtpDir, [{test, "test.beam"}]))].

filter_warnings_test_() ->
  [?_assertEqual([foo],
                 filter_warnings(all, [foo])),
   ?_assertEqual([],
                 filter_warnings(all, [])),
   ?_assertEqual([],
                 filter_warnings([],    [{error, {"src/foo.erl", 1}, bla}])),
   ?_assertEqual([],
                 filter_warnings([bar], [{error, {"src/foo.erl", 1}, bla}])),
   ?_assertEqual([{error, {"src/foo.erl", 1}, bla}],
                 filter_warnings([foo],  [{error, {"src/foo.erl", 1}, bla},
                                          {error, {"src/bar.erl", 1}, bla}])),
   ?_assertEqual([{error, {"src/foo.erl", 1}, bla}],
                 filter_warnings([foo, bar], [{error, {"src/foo.erl", 1}, bla}]))
  ].

format_warnings_test_() ->
  [{setup,
    fun() ->
        meck:unload(),
        meck:new(dialyzer),
        meck:expect(dialyzer, format_warning,
                    fun({foo, {"file", 1337}, "warning"}) -> "warning" end)
    end,
    fun(_) ->
        meck:unload()
    end,
    [?_assertEqual([{warning, "file", 1337, "warning"}],
                   format_warnings([{foo, {"file", 1337}, "warning"}]))]}].


%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:

