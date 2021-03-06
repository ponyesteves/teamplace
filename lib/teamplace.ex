defmodule Teamplace do
  @moduledoc """
    Documentation for Teamplace Wrapper API.
  """

  alias Teamplace.Helper

  @doc """
  Get Data, receives credentials type, resource (i.e. "reportes" || "facturaCompras"), action (i.e. "list")
  and returns a response Map
  """
  @type credentials :: %{client_id: String.t(), client_secret: String.t()}
  @spec get_data(credentials, String.t(), String.t(), Map.t()) :: Map.t()
  def get_data(credentials, resource, action, params \\ nil) do
    case HTTPoison.get!(
           url_factory(credentials, resource, action, params),
           [],
           recv_timeout: :infinity
         ) do
      # status_code if invalid token
      %HTTPoison.Response{status_code: 406, body: _body} ->
        new_token(credentials)
        get_data(credentials, resource, action)

      %HTTPoison.Response{body: ""} ->
        []

      %HTTPoison.Response{body: body} ->
        Poison.decode!(body)
    end
  end

  @doc """
  get_stream(Mate.Accounts.get_user!(1).credentials, "reports", "saldosprov")
  """
  def get_stream(credentials, resource, action, params \\ nil) do
    # Starts buffer
    buffer_pid = spawn(fn -> buffer() end)

    # Request JSON Chunked Data
    HTTPoison.get!(
      url_factory(credentials, resource, action, params),
      [],
      recv_timeout: :infinity,
      stream_to: buffer_pid
    )

    # Returns Stream
    create_stream(buffer_pid)
  end

  @doc """
  Get's actual token is exists or generates new one
  """
  def get_token(%{client_id: client_id} = credentials) do
    Agent.get(:teamplace, & &1[client_id]) || new_token(credentials)
  end

  @doc """
    Posts json data to teamplace resource
  """
  def post_data(credentials, resource, data) do
    headers = [{"content-type", "application/json"}]

    case HTTPoison.post(url_factory(credentials, resource), data, headers) do
      {:ok, %HTTPoison.Response{status_code: 406}} ->
        new_token(credentials)
        post_data(credentials, resource, data)

      {:ok, %HTTPoison.Response{status_code: 200}} ->
        {:ok, "Registro Creado"}

      {_, e} ->
        IO.inspect(e)
        {:error, "Hubo un error"}
    end
  end

  def url_factory(credentials, resource) do
    api_base(credentials) <>
      resource <>
      "?ACCESS_TOKEN=" <> get_token(credentials)
  end

  def url_factory(credentials, resource, action, params \\ nil) do
    api_base(credentials) <>
      resource <>
      "/" <>
      action <> "?ACCESS_TOKEN=" <> get_token(credentials) <> Helper.param_query_parser(params)
  end

  defp api_base(credentials) do
    credentials[:api_base] || Application.get_env(:teamplace, :api_base)
  end

  defp buffer({data, _status} = acc \\ {[], :stream}, remanent \\ "") do
    receive do
      %HTTPoison.AsyncStatus{code: 200} ->
        buffer({data, :stream})

      %HTTPoison.AsyncHeaders{} ->
        buffer({data, :stream})

      %HTTPoison.AsyncChunk{chunk: chunk} ->
        capture = Regex.named_captures(~r/\[?(?<complete>.*})?(?<incomplete>.*)\]?/, chunk)
        partial_content = remanent <> capture["complete"]
        next = extract_maps_if_any(partial_content)

        buffer(
          {data ++ next, :stream},
          create_chunk_remanent(next, partial_content, capture["incomplete"])
        )

      %HTTPoison.AsyncEnd{} ->
        buffer({data, :end})

      {:deliver, request_pid} ->
        case acc do
          {[], :end} ->
            send(request_pid, {:end})

          {[], :stream} ->
            send(request_pid, {:wait})
            buffer({[], :stream}, remanent)

          {[head | tail], :end} ->
            send(request_pid, {:response, head})
            buffer({tail, :end})

          {[head | tail], :stream} ->
            send(request_pid, {:response, head})
            buffer({tail, :stream}, remanent)
        end

      _ ->
        buffer({data, :stream}, remanent)
    end
  end

  defp create_stream(buffer_pid) do
    Stream.resource(
      fn ->
        nil
      end,
      fn _acc ->
        send(buffer_pid, {:deliver, self()})

        receive do
          {:response, item} ->
            {[item], nil}

          {:wait} ->
            IO.puts("sleeping")
            :timer.sleep(500)
            {[], nil}

          {:end} ->
            {:halt, nil}
        end
      end,
      fn _ -> nil end
    )
    |> Stream.map(&try_decode/1)
  end

  defp create_chunk_remanent([], partial_content, incomplete) do
    (partial_content <> incomplete)
    |> String.replace(~r/^,(?={)/, "")
  end

  defp create_chunk_remanent(_, _partial_content, incomplete) do
    incomplete
    |> String.replace(~r/^,(?={)/, "")
  end

  defp extract_maps_if_any(partial_content) do
    if partial_content |> String.match?(~r/(?<=}),/) do
      partial_content |> String.split(~r/(?<=}),/)
    else
      []
    end
  end

  defp extract_maps_if_any(partial_content) do
    if partial_content |> String.match?(~r/(?<=}),/) do
      partial_content |> String.split(~r/(?<=}),/)
    else
      []
    end
  end

  defp try_decode(item) do
    try do
      Poison.decode!(item)
    rescue
      _ ->
        IO.puts("ERROR DECODING ITEM")
        %{}
    end
  end

  defp save_session(token, credentials) do
    Agent.update(:teamplace, &Map.put(&1, credentials["client_id"], token))
    token
  end

  defp new_token(credentials) do
    case HTTPoison.get!(auth_url(credentials)) do
      %HTTPoison.Response{status_code: 406} ->
        raise ArgumentError, message: "check client_id or client_secret"

      %HTTPoison.Response{status_code: 500} ->
        raise ArgumentError, message: "Probably credentials expired. Renew on teamplace and try again"
      response ->
        response
        |> Map.get(:body)
        |> save_session(credentials)
    end
  end

  defp auth_url(%{client_id: client_id, client_secret: client_secret} = credentials) do
    api_base(credentials) <>
      "oauth/token?grant_type=client_credentials&client_id=#{client_id}&client_secret=#{
        client_secret
      }"
  end
end
