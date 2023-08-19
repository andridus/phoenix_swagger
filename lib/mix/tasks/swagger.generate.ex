defmodule Mix.Tasks.PhoenixSwagger.Generate do
  use Mix.Task
  require Logger

  @recursive true

  @shortdoc "Generates swagger.json file based on phoenix router"

  @moduledoc """
  Generates swagger.json file based on phoenix router and controllers.
  Usage:
      mix phx.swagger.generate
  PhoenixSwagger file configuration must be defined in the project config, eg:
      config :your_app, :phoenix_swagger,
        swagger_files: %{
          "priv/static/swagger.json" => [router: YourAppWeb.Router, endpoint: YourAppWeb.Endpoint]
          # ... additional swagger files can be added here
        }
  """

  @default_title "<enter your title>"
  @default_version "0.0.1"

  defp app_name, do: Mix.Project.get!().project()[:app]

  def run(_args) do
    Mix.Task.run("compile")
    Mix.Task.reenable("swagger.generate")
    Code.append_path(Mix.Project.compile_path())

    swagger_files =
      app_name()
      |> Application.get_env(:swagger, [])
      |> Keyword.get(:swagger_files, %{})

    if Enum.empty?(swagger_files) && !Mix.Task.recursing?() do
      Logger.warn("""
      No swagger configuration found. Ensure phoenix_swagger is configured, eg:
      config #{inspect(app_name())}, :phoenix_swagger,
        swagger_files: %{
          ...
        }
      """)
    end

    Enum.each(swagger_files, fn {output_file, config} ->
      result =
        with {:ok, router} <- attempt_load(config[:router]),
             {:ok, endpoint} <- attempt_load(config[:endpoint]) do
          write_file(output_file, swagger_document(router, endpoint))
        end

      case result do
        :ok -> Logger.info("PhoenixSwagger Updated!")
        {:error, reason} -> Logger.warn("Failed to generate #{output_file}: #{reason}")
      end
    end)
  end

  defp write_file(output_file, contents) do
    directory = Path.dirname(output_file)

    unless File.exists?(directory) do
      File.mkdir_p!(directory)
    end

    case File.read(output_file) do
      {:ok, ^contents} ->
        :ok

      _ ->
        File.write!(output_file, contents)
        IO.puts("#{app_name()}: generated #{output_file}")
    end
  end

  defp attempt_load(nil), do: {:ok, nil}

  defp attempt_load(module_name) do
    case Code.ensure_compiled(module_name) do
      {:module, result} -> {:ok, result}
      {:error, reason} -> {:error, "Failed to load module: #{module_name}: #{reason}"}
    end
  end

  defp swagger_document(router, endpoint) do
    router
    |> collect_info()
    |> collect_host(endpoint)
    |> collect_paths(router)
    |> collect_definitions(router)
    |> PhoenixSwagger.json_library().encode!(pretty: true)
  end

  defp collect_info(router) do
    cond do
      function_exported?(router, :swagger_info, 0) ->
        Map.merge(default_swagger_info(), router.swagger_info())

      function_exported?(Mix.Project.get(), :swagger_info, 0) ->
        info =
          Mix.Project.get().swagger_info()
          |> Keyword.put_new(:title, @default_title)
          |> Keyword.put_new(:version, @default_version)
          |> Enum.into(%{})

        %{default_swagger_info() | info: info}

      true ->
        default_swagger_info()
    end
  end

  def default_swagger_info do
    %{
      swagger: "1.0",
      openapi: "3.0.0",
      info: %{
        title: @default_title,
        version: @default_version
      },
      paths: %{},
      definitions: %{},
      customOptions: %{
        defaultModelsExpandDepth: -1,
        tagsSorter: "alpha",
        operationsSorter: "alpha",
        docExpansion: "none"
      }
    }
  end

  defp collect_paths(swagger_map, router) do
    base_module =
      app_name()
      |> Application.get_env(:swagger, [])
      |> Keyword.get(:base_module)
    router.__routes__()
    |> Enum.map(&find_swagger_path_function/1)
    |> Enum.filter(&String.starts_with?("#{&1[:controller]}", "Elixir.#{base_module}"))
    |> then(fn x ->
      Enum.map(x, fn y ->
        get_docs(y.controller)
        |> List.keyfind(y.action, 0)
        |> parse_doc(y)
      end)
    end)
    |> Enum.reduce(swagger_map, &merge_paths/2)
  end

  defp parse_doc(nil, module) do
    raise("ERROR: Not found documentation for '#{module.action}' in '#{module.controller}'.")
  end

  defp parse_doc({fun, doc}, module) do
    String.splitter(doc, ["---| swagger |---", "---| end |---"])
    |> Enum.take(3)
    |> case do
      [description, sw, _] ->
        description = String.trim(description)

        ~s(summary \"#{description}\" \n description \"#{description}\" \n #{sw})
        |> Code.string_to_quoted()
        |> case do
          {:ok, {_, _, tail}} ->
            body =
              Enum.reduce(
                tail,
                Macro.escape(%PhoenixSwagger.Path.PathObject{}),
                &quote do
                  unquote(&2) |> unquote(&1)
                end
              )

            quote do
              import PhoenixSwagger.Path
              unquote(body)
            end
            |> Code.eval_quoted()
            |> then(
              &(elem(&1, 0)
                |> PhoenixSwagger.ensure_operation_id(module.controller, fun)
                |> PhoenixSwagger.ensure_tag(module.controller)
                |> PhoenixSwagger.ensure_verb_and_path(module)
                |> PhoenixSwagger.Path.nest()
                |> PhoenixSwagger.to_json())
            )

          e ->
            Logger.error(
              error: "Check error on '#{module.controller} at '#{fun}' !! NOT EXPORTED",
              metadata: e
            )
        end

      e ->
        Logger.error(
          error: "Check error on '#{module.controller} at '#{fun}' !! NOT EXPORTED",
          metadata: e
        )
    end
  end

  defp find_swagger_path_function(route = %{opts: action, path: path, verb: verb})
       when is_atom(action) do
    generate_swagger_path_function(route, action, path, verb)
  end

  # In Phoenix >= 1.4.7 the `opts` key was renamed to `plug_opts`
  defp find_swagger_path_function(route = %{plug_opts: action, path: path, verb: verb})
       when is_atom(action) do
    generate_swagger_path_function(route, action, path, verb)
  end

  defp find_swagger_path_function(_route) do
    # action not an atom usually means route to a plug which isn't a Phoenix controller
    nil
  end

  defp get_docs(module) do
    Code.fetch_docs(module)
    |> case do
      {_, _, _, _, _, _, arr} ->
        Enum.map(arr, fn
          {{_, _function, _}, _, _, :hidden, _} -> :none
          {{_, _function, _}, _, _, :none, _} -> :none
          {{_, function, _}, _, _, doc, _} -> {function, doc["en"]}
        end)
        |> Enum.filter(&(&1 != :none))

      _ ->
        []
    end
  end

  defp generate_swagger_path_function(route, action, path, verb) do
    controller = find_controller(route)

    swagger_fun = "swagger_path_#{action}" |> String.to_atom()

    loaded? = Code.ensure_compiled(controller)

    case loaded? do
      {:module, _} ->
        %{
          controller: controller,
          swagger_fun: swagger_fun,
          path: format_path(path),
          action: action,
          verb: verb
        }

      _ ->
        Logger.warn("Warning: #{controller} module didn't load.")
        nil
    end
  end

  defp format_path(path) do
    Regex.replace(~r/:([^\/]+)/, path, "{\\1}")
  end

  defp merge_paths(path, swagger_map) do
    paths = Map.merge(swagger_map.paths, path, &merge_conflicts/3)
    %{swagger_map | paths: paths}
  end

  defp merge_conflicts(_key, value1, value2) do
    Map.merge(value1, value2)
  end

  defp collect_host(swagger_map, nil), do: swagger_map

  defp collect_host(swagger_map, endpoint) do
    endpoint_config = Application.get_env(app_name(), endpoint)

    case Keyword.get(endpoint_config, :url) do
      nil -> swagger_map
      _ -> collect_host_from_endpoint(swagger_map, endpoint_config)
    end
  end

  defp collect_host_from_endpoint(swagger_map, endpoint_config) do
    swgger_env =
      app_name()
      |> Application.get_env(:swagger, [])

    load_from_system_env = Keyword.get(endpoint_config, :load_from_system_env, false)
    host = Keyword.get(swgger_env, :host, "localhost")
    port = Keyword.get(swgger_env, :host, 4000)
    scheme = Keyword.get(swgger_env, :scheme)

    swagger_map =
      if !load_from_system_env and is_binary(host) and (is_integer(port) or is_binary(port)) do
        port = if port == 80, do: "", else: ":#{port}"
        Map.put_new(swagger_map, :host, "#{host}#{port}")
      else
        # host / port may be {:system, "ENV_VAR"} tuples or loaded in Endpoint.init callback
        swagger_map
      end

    case scheme do
      nil ->
        swagger_map

      _ ->
        Map.put_new(swagger_map, :schemes, ["https", "http"])
    end
  end

  defp collect_definitions(swagger_map, router) do
    router.__routes__()
    |> Enum.map(&find_controller/1)
    |> Enum.uniq()
    |> Enum.filter(&function_exported?(&1, :swagger_definitions, 0))
    |> Enum.map(& &1.swagger_definitions())
    |> Enum.reduce(swagger_map, &merge_definitions/2)
  end

  defp find_controller(route_map) do
    Module.concat([:"Elixir" | Module.split(route_map.plug)])
  end

  defp merge_definitions(definitions, %{definitions: existing} = swagger_map) do
    %{swagger_map | definitions: Map.merge(existing, definitions)}
  end
end
