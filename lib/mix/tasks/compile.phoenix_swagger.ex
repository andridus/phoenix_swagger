defmodule Mix.Tasks.Compile.PhoenixSwagger do
  use Mix.Task

  @shortdoc "Compiles swagger annotations to JSON file"

  @moduledoc """
  See documentation for `Mix.Tasks.Phx.PhoenixSwagger.Generate`
  """

  def run(_args) do
    case Mix.Task.run("phx.swagger.generate") do
      results when is_list(results) ->
        errors = filter_errors(results)
        if Enum.empty?(errors), do: :ok, else: :error

      result ->
        result
    end
  end

  def filter_errors(results) do
    Enum.filter(
      results,
      fn
        :error -> true
        {:error, _} -> true
        _ -> false
      end
    )
  end
end
