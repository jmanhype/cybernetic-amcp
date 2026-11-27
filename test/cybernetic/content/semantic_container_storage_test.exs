defmodule Cybernetic.Content.SemanticContainerStorageTest do
  @moduledoc """
  Round-trip proof for SemanticContainer's storage calls, against the
  real storage stack (Cybernetic.Storage facade over the Memory adapter).

  Regression context: SemanticContainer invoked its storage adapter as
  `put(path, content, tenant_id)` / `get(path, tenant_id)` /
  `delete(path, tenant_id)`, while the canonical
  `Cybernetic.Storage.Adapter` contract is `(tenant_id, path, content)` /
  `(tenant_id, path)`. The only prior coverage used a test double written
  to match the wrong call shape, so the real persist path was never
  exercised. These tests exist so the container is proven against the
  real contract.
  """
  use ExUnit.Case, async: false

  alias Cybernetic.Content.SemanticContainer
  alias Cybernetic.Storage
  alias Cybernetic.Storage.Adapters.Memory

  @tenant "tenant-semstore"

  setup do
    if Process.whereis(Memory) == nil do
      start_supervised!(Memory)
    end

    Memory.clear()

    previous = Application.get_env(:cybernetic, :storage, [])
    Application.put_env(:cybernetic, :storage, Keyword.put(previous, :adapter, Memory))
    on_exit(fn -> Application.put_env(:cybernetic, :storage, previous) end)

    container_name = :"semantic_storage_#{System.unique_integer([:positive])}"
    start_supervised!({SemanticContainer, [name: container_name]})

    %{server: container_name}
  end

  test "created content round-trips through real storage", %{server: server} do
    content = "semantic storage round trip content"

    assert {:ok, container} = SemanticContainer.create(server, content, @tenant)

    # Persisted under the canonical tenant/path, readable via Storage itself
    path = "containers/#{container.content_hash}"
    assert {:ok, ^content} = Storage.get(@tenant, path)

    # And readable back through the container's own fetch path
    assert {:ok, _fetched, ^content} = SemanticContainer.get_with_content(server, container.id)

    # Delete removes the object from storage, not just from the index
    assert :ok = SemanticContainer.delete(server, container.id)
    assert {:error, _} = Storage.get(@tenant, path)
  end

  test "content is isolated under its own tenant namespace", %{server: server} do
    content = "tenant scoped semantic content"

    assert {:ok, container} = SemanticContainer.create(server, content, @tenant)
    path = "containers/#{container.content_hash}"

    assert {:error, _} = Storage.get("some-other-tenant", path)
    assert {:ok, ^content} = Storage.get(@tenant, path)
  end
end
