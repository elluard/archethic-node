defmodule Migration_1_4_8 do
  @moduledoc """
  Replicate and ingest io transaction on genesis storage pool
  """

  alias Archethic.UTXO.Loader
  alias Archethic.UTXO.DBLedger
  alias Archethic.UTXO.MemoryLedger

  alias Archethic.BeaconChain
  alias Archethic.BeaconChain.ReplicationAttestation
  alias Archethic.BeaconChain.SummaryAggregate

  alias Archethic.Crypto

  alias Archethic.Election

  alias Archethic.P2P

  alias Archethic.Replication



  alias Archethic.TransactionChain
  alias Archethic.TransactionChain.Transaction
  alias Archethic.TransactionChain.Transaction.ValidationStamp
  alias Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations

  alias Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations.UnspentOutput

  alias Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations.VersionedUnspentOutput

  alias Archethic.TransactionChain.TransactionSummary

  alias Archethic.Utils

  require Logger

  @table_name :archethic_utxo_ledger
  @table_stats_name :archethic_utxo_ledger_stats
  @last_protocol_version 7

  def run() do
    authorized_nodes = P2P.authorized_and_available_nodes()

    node_key = Crypto.first_node_public_key()

    elected_genesis_addresses =
      P2P.get_first_enrolled_node()
      |> Map.get(:enrollment_date)
      |> BeaconChain.next_summary_dates()
      |> Stream.flat_map(fn summary_date ->
        Logger.debug("Migration_1_4_8 - Fetch genesis addresses for summary at #{summary_date}")

        summary_date
        |> get_summary_replication_attestations(authorized_nodes)
        |> fetch_elected_genesis_addresses(authorized_nodes, node_key)
      end)
      |> Enum.uniq()
      |> Enum.with_index()

    nb_genesis_addresses = length(elected_genesis_addresses)
    # Log each 5 %
    log_index_rate = ceil(nb_genesis_addresses / 20)
    Logger.debug("Migration_1_4_8 - Retrieved #{nb_genesis_addresses} genesis addresses to store")

    Task.Supervisor.async_stream(
      Archethic.task_supervisors(),
      elected_genesis_addresses,
      fn {genesis_address, index} ->
        last_chain_address = fetch_last_chain_address(genesis_address, authorized_nodes)

        last_transaction =
          if last_chain_address != genesis_address,
            do: fetch_transaction(last_chain_address, authorized_nodes),
            else: nil

          if not is_nil(last_transaction) && not TransactionChain.transaction_exists?(last_chain_address) do
            Replication.sync_transaction_chain(last_transaction, genesis_address, authorized_nodes,
              self_repair: true
            )
          end


        inputs = fetch_transaction_inputs(last_chain_address, authorized_nodes)

        ingest_inputs(genesis_address, last_transaction, inputs)

        if rem(index, log_index_rate) == 0 do
          percentage = (index * 100 / nb_genesis_addresses) |> Float.round(2)
          Logger.debug("Migration_1_4_8 - Processed #{percentage}% of genesis addresses")
        end
      end,
      timeout: :infinity
    )
    |> Stream.run()
  end

  defp get_summary_replication_attestations(summary_date, authorized_nodes) do
    nodes =
      summary_date
      |> Crypto.derive_beacon_aggregate_address()
      |> Election.chain_storage_nodes(authorized_nodes)

    case BeaconChain.fetch_summaries_aggregate(summary_date, nodes) do
      {:ok, %SummaryAggregate{replication_attestations: attestations}} ->
        attestations

      {:error, reason} ->
        raise "Migration_1_4_8 failed to download aggregate for #{summary_date} with #{reason}"
    end
  end

  defp fetch_elected_genesis_addresses(attestations, authorized_nodes, node_key) do
    Task.Supervisor.async_stream(
      Archethic.task_supervisors(),
      attestations,
      fn %ReplicationAttestation{
           transaction_summary: %TransactionSummary{
             address: tx_address,
             movements_addresses: movements_addresses
           }
         } ->
        [tx_address | movements_addresses]
        |> fetch_genesis_addresses(authorized_nodes)
        |> Enum.filter(&genesis_node?(&1, authorized_nodes, node_key))
      end,
      timeout: :infinity,
      max_concurrency: 4
    )
    |> Stream.flat_map(fn {:ok, genesis_addresses} -> genesis_addresses end)
    |> Stream.uniq()
  end

  defp fetch_genesis_addresses(addresses, authorized_nodes) do
    Task.Supervisor.async_stream(
      Archethic.task_supervisors(),
      addresses,
      fn address ->
        storage_nodes = Election.storage_nodes(address, authorized_nodes)
        TransactionChain.fetch_genesis_address(address, storage_nodes)
      end,
      max_concurrency: 4
    )
    |> Stream.map(fn {:ok, {:ok, genesis_address}} -> genesis_address end)
  end

  defp genesis_node?(genesis_address, authorized_nodes, node_key) do
    genesis_address
    |> Election.storage_nodes(authorized_nodes)
    |> Utils.key_in_node_list?(node_key)
  end

  defp fetch_last_chain_address(genesis_address, authorized_nodes) do
    storage_nodes = Election.storage_nodes(genesis_address, authorized_nodes)

    case TransactionChain.fetch_last_address(genesis_address, storage_nodes) do
      {:ok, last_address} ->
        last_address

      {:error, reason} ->
        raise "Migration_1_4_8 failed to fetch last address for genesis #{Base.encode16(genesis_address)} with #{reason}"
    end
  end

  defp fetch_transaction(address, authorized_nodes) do
    storage_nodes = Election.storage_nodes(address, authorized_nodes)

    case TransactionChain.fetch_transaction(address, storage_nodes) do
      {:ok, transaction} ->
        transaction

      {:error, reason} ->
        raise "Migration_1_4_8 failed to fetch transaction #{Base.encode16(address)} with #{reason}"
    end
  end

  defp fetch_transaction_inputs(address, authorized_nodes) do
    storage_nodes = Election.storage_nodes(address, authorized_nodes)
    TransactionChain.fetch_inputs(address, storage_nodes, DateTime.utc_now())
  end

  defp ingest_inputs(genesis_address, nil, inputs) do
    # Delete memory table and DB file before inserting entire utxos
    DBLedger.flush(genesis_address, [])
    :ets.delete(@table_name, genesis_address)
    :ets.delete(@table_stats_name, genesis_address)

    Enum.each(inputs, &ingest_input(genesis_address, &1))
  end

  defp ingest_inputs(
         genesis_address,
         %Transaction{
           validation_stamp: %ValidationStamp{
             protocol_version: version,
             ledger_operations: %LedgerOperations{unspent_outputs: unspent_outputs}
           }
         },
         inputs
       ) do
    # We need to use tx unspent outputs as fetch inputs does not return the contract state
    versionned_utxos =
      unspent_outputs
      |> Enum.filter(&(&1.amount == nil or &1.amount > 0))
      |> VersionedUnspentOutput.wrap_unspent_outputs(version)

    # Delete memory table before inserting entire utxos
    :ets.delete(@table_name, genesis_address)
    :ets.delete(@table_stats_name, genesis_address)

    DBLedger.flush(genesis_address, versionned_utxos)
    Enum.each(versionned_utxos, &MemoryLedger.add_chain_utxo(genesis_address, &1))

    unspent_outputs
    |> filter_pending_inputs(inputs)
    |> Enum.each(&ingest_input(genesis_address, &1))
  end

  defp filter_pending_inputs(unspent_outputs, inputs) do
    mapped_utxos = Enum.map(unspent_outputs, &{&1.type, &1.from, &1.amount})
    Enum.reject(inputs, &Enum.member?(mapped_utxos, {&1.type, &1.from, &1.amount}))
  end

  defp ingest_input(genesis_address, input) do
    input
    |> UnspentOutput.cast()
    |> VersionedUnspentOutput.wrap_unspent_output(@last_protocol_version)
    |> Loader.add_utxo(genesis_address)
  end
end
