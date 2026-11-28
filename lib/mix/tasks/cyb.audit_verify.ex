defmodule Mix.Tasks.Cyb.AuditVerify do
  use Mix.Task

  @shortdoc "Verify the hash-chained audit log (IP-27)"

  @moduledoc """
  Verifies the Phase 1 audit log's hash chain directly from the
  JSONL files on disk. The running system is not consulted — this
  checker does not need its cooperation.

      mix cyb.audit_verify                 # verify the configured audit dir
      mix cyb.audit_verify --dir priv/audit
      mix cyb.audit_verify --file priv/audit/audit-2026-11-28.jsonl

  For each file: every line parses, sequence numbers are
  consecutive, each `prev_hash` matches the previous entry's hash,
  each entry hash recomputes, and each `daily_anchor`'s Merkle root
  matches the day's entries. Directory verification additionally
  checks chain continuity across files and that every past day ends
  with its anchor.

  Exits non-zero (via `Mix.raise/1`) naming the file, the first bad
  entry's sequence number, and the failure reason.
  """

  alias Cybernetic.Audit.Log

  @doc """
  Runs the verification. See the moduledoc for usage.
  """
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _remaining, _invalid} =
      OptionParser.parse(args, switches: [dir: :string, file: :string])

    # Deliberately no app.start: verification reads files directly.
    results =
      case Keyword.get(opts, :file) do
        nil ->
          dir =
            Keyword.get(opts, :dir) ||
              Application.get_env(:cybernetic, :audit_log_dir, "priv/audit")

          [{dir, Log.verify_dir(dir)}]

        file ->
          [{file, Log.verify_file(file)}]
      end

    failures =
      Enum.filter(results, fn
        {_target, {:error, _detail}} -> true
        _other -> false
      end)

    Enum.each(results, fn
      {target, {:ok, info}} ->
        IO.puts("OK #{target}: #{info.entries} entries, #{info.anchors} anchor(s) verified")

      {target, {:error, detail}} ->
        IO.puts(
          "FAIL #{target}: seq #{inspect(detail[:seq])} " <>
            "#{detail.reason} #{inspect(detail[:detail])}"
        )
    end)

    if failures != [] do
      Mix.raise("Audit verification failed for #{length(failures)} target(s)")
    end

    :ok
  end
end
