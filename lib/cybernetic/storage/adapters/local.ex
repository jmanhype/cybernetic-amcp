defmodule Cybernetic.Storage.Adapters.Local do
  @moduledoc """
  Local filesystem storage adapter.

  Stores artifacts on the local filesystem with tenant isolation.

  ## Configuration

      config :cybernetic, :storage,
        adapter: Cybernetic.Storage.Adapters.Local,
        base_path: "/var/data/cybernetic"

  ## Directory Structure

      base_path/
        tenant-1/
          artifacts/
            file1.json
            file2.bin
        tenant-2/
          artifacts/
            file3.json
  """
  use Cybernetic.Storage.Adapter

  require Logger

  alias Cybernetic.Storage.PathValidator

  @default_base_path "/tmp/cybernetic/storage"
  @default_chunk_size 65_536

  @impl true
  @spec put(String.t(), String.t(), binary(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def put(tenant_id, path, content, opts \\ []) do
    with {:ok, full_path} <- build_full_path(tenant_id, path),
         :ok <- ensure_directory(full_path),
         :ok <- File.write(full_path, content) do
      content_type = Keyword.get(opts, :content_type, detect_content_type(path))
      metadata = Keyword.get(opts, :metadata, %{})

      artifact = %{
        path: path,
        size: byte_size(content),
        content_type: content_type,
        etag: compute_etag(content),
        last_modified: DateTime.utc_now(),
        metadata: metadata
      }

      Logger.debug("Stored artifact",
        tenant: tenant_id,
        path: path,
        size: artifact.size
      )

      {:ok, artifact}
    else
      {:error, :enoent} -> {:error, :storage_error}
      {:error, :eacces} -> {:error, :permission_denied}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      error -> {:error, {:storage_error, error}}
    end
  end

  @impl true
  @spec get(String.t(), String.t()) :: {:ok, binary()} | {:error, atom()}
  def get(tenant_id, path) do
    with {:ok, full_path} <- build_full_path(tenant_id, path) do
      case File.read(full_path) do
        {:ok, content} ->
          {:ok, content}

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, :eacces} ->
          {:error, :permission_denied}

        {:error, reason} ->
          {:error, {:storage_error, reason}}
      end
    end
  end

  @impl true
  @spec stream(String.t(), String.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, atom()}
  def stream(tenant_id, path, opts \\ []) do
    with {:ok, full_path} <- build_full_path(tenant_id, path),
         {:ok, true} <- exists?(tenant_id, path) do
      chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)

      stream =
        File.stream!(full_path, [], chunk_size)
        |> Stream.map(fn chunk -> chunk end)

      {:ok, stream}
    else
      {:ok, false} -> {:error, :not_found}
      error -> error
    end
  rescue
    e in File.Error ->
      Logger.error("Stream error", error: e.reason)
      {:error, {:storage_error, e.reason}}
  end

  @impl true
  @spec delete(String.t(), String.t()) :: :ok | {:error, atom()}
  def delete(tenant_id, path) do
    with {:ok, full_path} <- build_full_path(tenant_id, path) do
      case File.rm(full_path) do
        :ok ->
          Logger.debug("Deleted artifact", tenant: tenant_id, path: path)
          :ok

        {:error, :enoent} ->
          # Already deleted, treat as success
          :ok

        {:error, :eacces} ->
          {:error, :permission_denied}

        {:error, reason} ->
          {:error, {:storage_error, reason}}
      end
    end
  end

  @impl true
  @spec exists?(String.t(), String.t()) :: {:ok, boolean()} | {:error, atom()}
  def exists?(tenant_id, path) do
    with {:ok, full_path} <- build_full_path(tenant_id, path) do
      {:ok, File.exists?(full_path)}
    end
  end

  @impl true
  @spec list(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, atom()}
  def list(tenant_id, prefix, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, false)
    limit = Keyword.get(opts, :limit)

    with {:ok, base_path} <- build_full_path(tenant_id, prefix) do
      if File.dir?(base_path) do
        files =
          if recursive do
            list_recursive(base_path)
          else
            list_directory(base_path)
          end

        artifacts =
          files
          |> Enum.map(&build_artifact_info(tenant_id, prefix, &1))
          |> Enum.filter(&(&1 != nil))
          |> maybe_limit(limit)

        {:ok, artifacts}
      else
        # If prefix is a file, return empty list
        {:ok, []}
      end
    end
  rescue
    e ->
      Logger.error("List error", error: inspect(e))
      {:error, :storage_error}
  end

  @impl true
  @spec stat(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def stat(tenant_id, path) do
    with {:ok, full_path} <- build_full_path(tenant_id, path) do
      case File.stat(full_path) do
        {:ok, %File.Stat{size: size, mtime: mtime, type: :regular}} ->
          artifact = %{
            path: path,
            size: size,
            content_type: detect_content_type(path),
            etag: nil,
            last_modified: naive_to_datetime(mtime),
            metadata: %{}
          }

          {:ok, artifact}

        {:ok, %File.Stat{type: :directory}} ->
          {:error, :invalid_path}

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, :eacces} ->
          {:error, :permission_denied}

        {:error, reason} ->
          {:error, {:storage_error, reason}}
      end
    end
  end

  # Private functions

  defp build_full_path(tenant_id, path) do
    base_path = get_base_path()
    PathValidator.build_path(base_path, tenant_id, path)
  end

  defp get_base_path do
    Application.get_env(:cybernetic, :storage, [])
    |> Keyword.get(:base_path, @default_base_path)
  end

  defp ensure_directory(file_path) do
    dir = Path.dirname(file_path)

    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  defp compute_etag(content) do
    :crypto.hash(:md5, content)
    |> Base.encode16(case: :lower)
  end

  defp detect_content_type(path) do
    ext = Path.extname(path) |> String.downcase()

    case ext do
      ".json" -> "application/json"
      ".html" -> "text/html"
      ".txt" -> "text/plain"
      ".xml" -> "application/xml"
      ".css" -> "text/css"
      ".js" -> "application/javascript"
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".svg" -> "image/svg+xml"
      ".pdf" -> "application/pdf"
      ".zip" -> "application/zip"
      ".gz" -> "application/gzip"
      _ -> "application/octet-stream"
    end
  end

  defp list_directory(path) do
    case File.ls(path) do
      {:ok, files} ->
        Enum.map(files, &Path.join(path, &1))
        |> Enum.filter(&File.regular?/1)

      {:error, _} ->
        []
    end
  end

  defp list_recursive(path) do
    Path.wildcard(Path.join(path, "**/*"))
    |> Enum.filter(&File.regular?/1)
  end

  defp build_artifact_info(tenant_id, prefix, full_path) do
    base_path = get_base_path()
    tenant_path = Path.join(base_path, tenant_id)

    relative_path =
      full_path
      |> String.replace_prefix(tenant_path <> "/", "")

    case File.stat(full_path) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        %{
          path: relative_path,
          size: size,
          content_type: detect_content_type(full_path),
          etag: nil,
          last_modified: naive_to_datetime(mtime),
          metadata: %{}
        }

      _ ->
        nil
    end
  end

  defp maybe_limit(list, nil), do: list
  defp maybe_limit(list, limit), do: Enum.take(list, limit)

  defp naive_to_datetime({{year, month, day}, {hour, min, sec}}) do
    DateTime.new!(Date.new!(year, month, day), Time.new!(hour, min, sec))
  end
end
