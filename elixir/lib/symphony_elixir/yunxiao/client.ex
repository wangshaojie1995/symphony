defmodule SymphonyElixir.Yunxiao.Client do
  @moduledoc """
  HTTP client and issue normalization for Yunxiao Projex.
  """

  alias SymphonyElixir.{Config, Tracker.Issue}

  @central_host "openapi-rdc.aliyuncs.com"
  @central_api "https://#{@central_host}"
  @token_env "ALIBABA_CLOUD_YUNXIAO_ACCESS_TOKEN"
  @page_size 100
  @last_page div(10_000, @page_size)
  @id_pattern ~r/\A[A-Za-z0-9_-]+\z/
  @env_pattern ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker) do
    with :ok <- validate_states(tracker.active_states, :invalid_yunxiao_active_states),
         :ok <- validate_states(tracker.terminal_states, :invalid_yunxiao_terminal_states),
         {:ok, _settings} <- settings(tracker) do
      :ok
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states([]), do: {:ok, []}

  def fetch_issues_by_states(states) do
    with {:ok, settings} <- settings(Config.settings!().tracker) do
      condition = %{
        "fieldIdentifier" => "status",
        "operator" => "CONTAINS",
        "value" => states,
        "toValue" => nil,
        "className" => "status",
        "format" => "list"
      }

      body = %{
        "category" => settings.categories,
        "conditions" => Jason.encode!(%{"conditionGroups" => [[condition]]}),
        "spaceId" => settings.project_id,
        "spaceType" => "Project",
        "perPage" => @page_size
      }

      fetch_pages(settings, body, states, 1, [])
    end
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids([]), do: {:ok, []}

  def fetch_issues_by_ids(ids) do
    with {:ok, settings} <- settings(Config.settings!().tracker) do
      ids
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, &collect_issue_by_id(settings, &1, &2))
      |> case do
        {:ok, issues} -> {:ok, Enum.reverse(issues)}
        error -> error
      end
    end
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(%{provider: provider}) do
    case env_reference(provider["api_key"]) do
      nil -> [@token_env]
      name -> Enum.uniq([@token_env, name])
    end
  end

  @doc false
  @spec workitem_request(map(), atom(), String.t(), String.t(), map() | nil) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def workitem_request(tracker, method, id, suffix, body) do
    with {:ok, settings} <- settings(tracker),
         {:ok, response} <- fetch_workitem(settings, id) do
      case {method, suffix} do
        {:get, ""} -> {:ok, response}
        _ -> request(settings, method, "/workitems/#{id}#{suffix}", body)
      end
    else
      :missing -> {:error, :yunxiao_workitem_not_found}
      error -> error
    end
  end

  defp fetch_pages(settings, body, states, page, issues) do
    with {:ok, %Req.Response{body: items} = response} when is_list(items) <-
           request(settings, :post, "/workitems:search", Map.put(body, "page", page)),
         {:ok, next} <- next_page(response, page) do
      issues =
        for item <- items,
            {:ok, issue} <- [normalize_issue(item, settings)],
            issue.state in states,
            reduce: issues do
          acc -> [issue | acc]
        end

      case next do
        nil -> {:ok, issues |> Enum.reverse() |> Enum.uniq_by(& &1.id)}
        next -> fetch_pages(settings, body, states, next, issues)
      end
    else
      {:ok, _response} -> {:error, :invalid_yunxiao_payload}
      error -> error
    end
  end

  defp next_page(response, page) do
    case Req.Response.get_header(response, "x-next-page") do
      [] -> fallback_next_page(response, page)
      [value] when value in ["", "0"] -> {:ok, nil}
      [value] -> parse_next_page(Integer.parse(value), page)
      _ -> {:error, :invalid_yunxiao_pagination}
    end
  end

  defp fallback_next_page(response, page) do
    case Req.Response.get_header(response, "x-total-pages") do
      [value] ->
        next_page_from_total(Integer.parse(value), page)

      [] ->
        if length(response.body) == @page_size, do: parse_next_page({page + 1, ""}, page), else: {:ok, nil}

      _ ->
        {:error, :invalid_yunxiao_pagination}
    end
  end

  defp next_page_from_total({total, ""}, page) when total > page, do: parse_next_page({page + 1, ""}, page)
  defp next_page_from_total({total, ""}, _page) when total >= 0, do: {:ok, nil}
  defp next_page_from_total(_total, _page), do: {:error, :invalid_yunxiao_pagination}

  defp parse_next_page({next, ""}, page) when next == page + 1 and next <= @last_page, do: {:ok, next}
  defp parse_next_page({next, ""}, page) when next == page + 1, do: {:error, :yunxiao_search_window_exceeded}
  defp parse_next_page(_next, _page), do: {:error, :invalid_yunxiao_pagination}

  defp collect_issue_by_id(settings, id, {:ok, issues}) do
    result =
      with {:ok, response} <- fetch_workitem(settings, id) do
        normalize_issue(response.body, settings)
      end

    case result do
      {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
      :missing -> {:cont, {:ok, issues}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp fetch_workitem(%{project_id: project_id} = settings, id) do
    if valid_id?(id) do
      case request(settings, :get, "/workitems/#{id}") do
        {:ok, %Req.Response{body: %{"id" => ^id, "space" => %{"id" => ^project_id}}} = response} ->
          {:ok, response}

        {:ok, %Req.Response{body: %{"id" => ^id, "space" => %{"id" => other_id}}}} when is_binary(other_id) ->
          :missing

        {:ok, _response} ->
          {:error, :invalid_yunxiao_payload}

        {:error, {:yunxiao_api_status, 404}} ->
          :missing

        error ->
          error
      end
    else
      {:error, :invalid_yunxiao_workitem_id}
    end
  end

  defp normalize_issue(
         %{"id" => id, "serialNumber" => identifier, "subject" => title, "status" => %{"id" => state}, "space" => %{"id" => project_id}} = item,
         %{project_id: project_id}
       ) do
    if valid_id?(id) and valid_id?(state) and present?(identifier) and present?(title) do
      {:ok,
       %Issue{
         id: id,
         identifier: identifier,
         title: title,
         state: state,
         native_ref: %{"id" => id, "project_id" => project_id},
         description: string_or_nil(item["description"]),
         assignee_id: field(item["assignedTo"], "id"),
         labels: labels(item["labels"]),
         dispatchable: item["logicalStatus"] != "archived",
         created_at: datetime(item["gmtCreate"]),
         updated_at: datetime(item["gmtModified"])
       }}
    else
      {:error, :invalid_yunxiao_payload}
    end
  end

  defp normalize_issue(_item, _settings), do: {:error, :invalid_yunxiao_payload}

  defp labels(values) when is_list(values) do
    values
    |> Enum.map(&field(&1, "name"))
    |> Enum.filter(&present?/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.uniq()
  end

  defp labels(_values), do: []

  defp field(value, key) when is_map(value), do: string_or_nil(value[key])
  defp field(_value, _key), do: nil
  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      _ -> nil
    end
  end

  defp datetime(_value), do: nil

  defp request(settings, method, path, body \\ nil) do
    opts = [
      method: method,
      url: settings.api_url <> settings.prefix <> path,
      headers: [{"accept", "application/json"}, {"x-yunxiao-token", settings.api_key}],
      redirect: false,
      retry: false,
      receive_timeout: 30_000
    ]

    opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

    case Req.request(opts) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %Req.Response{status: status}} -> {:error, {:yunxiao_api_status, status}}
      {:error, _reason} -> {:error, :yunxiao_api_request_failed}
    end
  end

  defp settings(%{provider: provider}) do
    api_url = provider["api_url"] || @central_api
    organization_id = provider["organization_id"]
    project_id = provider["project_id"]
    categories = provider["categories"] || "Req,Bug,Task"
    api_key = resolve_api_key(provider["api_key"])

    cond do
      not valid_api_url?(api_url) ->
        {:error, :invalid_yunxiao_api_url}

      not valid_organization?(organization_id, api_url) ->
        {:error, :invalid_yunxiao_organization_id}

      not valid_id?(project_id) ->
        {:error, :invalid_yunxiao_project_id}

      not valid_categories?(categories) ->
        {:error, :invalid_yunxiao_categories}

      not present?(api_key) ->
        {:error, :missing_yunxiao_api_key}

      true ->
        {:ok,
         %{
           api_url: String.trim_trailing(api_url, "/"),
           api_key: String.trim(api_key),
           prefix: api_prefix(organization_id),
           project_id: project_id,
           categories: categories
         }}
    end
  end

  defp validate_states(states, error) do
    if is_list(states) and Enum.all?(states, &valid_id?/1), do: :ok, else: {:error, error}
  end

  defp valid_id?(value), do: is_binary(value) and Regex.match?(@id_pattern, value)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_categories?(value) do
    is_binary(value) and Enum.all?(String.split(value, ","), &valid_id?/1)
  end

  defp valid_organization?(nil, api_url), do: String.downcase(URI.parse(api_url).host) != @central_host
  defp valid_organization?(id, _api_url), do: valid_id?(id)

  defp valid_api_url?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, path: path, userinfo: nil, query: nil, fragment: nil}} ->
        present?(host) and path in [nil, "", "/"]

      _ ->
        false
    end
  end

  defp valid_api_url?(_value), do: false

  defp resolve_api_key(nil), do: System.get_env(@token_env)

  defp resolve_api_key("$" <> _name = value) do
    case env_reference(value) do
      nil -> nil
      name -> System.get_env(name)
    end
  end

  defp resolve_api_key(value), do: value

  defp env_reference("$" <> name), do: if(Regex.match?(@env_pattern, name), do: name)
  defp env_reference(_value), do: nil

  defp api_prefix(nil), do: "/oapi/v1/projex"
  defp api_prefix(organization_id), do: "/oapi/v1/projex/organizations/#{organization_id}"
end
