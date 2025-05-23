defmodule Archethic.Mining.LedgerValidationTest do
  alias Archethic.Mining.LedgerValidation

  alias Archethic.Reward.MemTables.RewardTokens

  alias Archethic.TransactionFactory

  alias Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations

  alias Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations.TransactionMovement

  alias Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations.UnspentOutput

  alias Archethic.TransactionChain.Transaction.ValidationStamp.LedgerOperations.VersionedUnspentOutput

  use ArchethicCase
  import ArchethicCase

  doctest LedgerValidation

  setup do
    start_supervised!(RewardTokens)
    :ok
  end

  describe "mint_token_utxos/4" do
    test "should raise if not in filtered_inputs state" do
      tx = TransactionFactory.create_valid_transaction([])

      assert_raise FunctionClauseError, fn ->
        %LedgerValidation{}
        |> LedgerValidation.mint_token_utxos(tx, DateTime.utc_now(), current_protocol_version())
      end
    end

    test "should update state to utxos_minted" do
      tx = TransactionFactory.create_valid_transaction([])

      assert %LedgerValidation{state: :utxos_minted} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(
                 tx,
                 DateTime.utc_now(),
                 current_protocol_version()
               )
    end

    test "should return empty list for non token/mint_reward transaction" do
      types = Archethic.TransactionChain.Transaction.types() -- [:node, :mint_reward]

      Enum.each(types, fn t ->
        assert %LedgerValidation{minted_utxos: []} =
                 %LedgerValidation{}
                 |> LedgerValidation.filter_usable_inputs([], nil)
                 |> LedgerValidation.mint_token_utxos(
                   TransactionFactory.create_valid_transaction([], type: t),
                   DateTime.utc_now(),
                   current_protocol_version()
                 )
      end)
    end

    test "should return empty list if content is invalid" do
      assert %LedgerValidation{minted_utxos: []} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(
                 TransactionFactory.create_valid_transaction([],
                   type: :token,
                   content: "not a json"
                 ),
                 DateTime.utc_now(),
                 current_protocol_version()
               )

      assert %LedgerValidation{minted_utxos: []} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(
                 TransactionFactory.create_valid_transaction([], type: :token, content: "{}"),
                 DateTime.utc_now(),
                 current_protocol_version()
               )
    end
  end

  describe "mint_token_utxos/4 with a token resupply transaction" do
    test "should return a utxo" do
      token_address = random_address()
      token_address_hex = token_address |> Base.encode16()
      now = DateTime.utc_now()

      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
          "token_reference": "#{token_address_hex}",
          "supply": 1000000
          }
          """
        )

      tx_address = tx.address

      assert [
               %UnspentOutput{
                 amount: 1_000_000,
                 from: ^tx_address,
                 type: {:token, ^token_address, 0},
                 timestamp: ^now
               }
             ] =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
               |> Map.fetch!(:minted_utxos)
               |> VersionedUnspentOutput.unwrap_unspent_outputs()
    end

    test "should return an empty list if invalid tx" do
      now = DateTime.utc_now()

      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
          "token_reference": "nonhexadecimal",
          "supply": 1000000
          }
          """
        )

      assert %LedgerValidation{minted_utxos: []} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())

      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
          "token_reference": {"foo": "bar"},
          "supply": 1000000
          }
          """
        )

      assert %LedgerValidation{minted_utxos: []} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())

      token_address = random_address()
      token_address_hex = token_address |> Base.encode16()

      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
          "token_reference": "#{token_address_hex}",
          "supply": "hello"
          }
          """
        )

      assert %LedgerValidation{minted_utxos: []} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
    end
  end

  describe "mint_token_utxos/4 with a token creation transaction" do
    test "should return a utxo (for fungible)" do
      now = DateTime.utc_now()

      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
            "supply": 1000000000,
            "type": "fungible",
            "decimals": 8,
            "name": "NAME OF MY TOKEN",
            "symbol": "MTK"
          }
          """
        )

      tx_address = tx.address

      assert [
               %UnspentOutput{
                 amount: 1_000_000_000,
                 from: ^tx_address,
                 type: {:token, ^tx_address, 0},
                 timestamp: ^now
               }
             ] =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
               |> Map.fetch!(:minted_utxos)
               |> VersionedUnspentOutput.unwrap_unspent_outputs()
    end

    test "should return a utxo (for non-fungible)" do
      now = DateTime.utc_now()

      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
            "supply": 100000000,
            "type": "non-fungible",
            "name": "My NFT",
            "symbol": "MNFT",
            "properties": {
               "image": "base64 of the image",
               "description": "This is a NFT with an image"
            }
          }
          """
        )

      tx_address = tx.address

      protocol_version = current_protocol_version()

      assert %LedgerValidation{
               minted_utxos: [
                 %VersionedUnspentOutput{
                   unspent_output: %UnspentOutput{
                     amount: 100_000_000,
                     from: ^tx_address,
                     type: {:token, ^tx_address, 1},
                     timestamp: ^now
                   },
                   protocol_version: ^protocol_version
                 }
               ]
             } =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
    end

    test "should return a utxo (for non-fungible collection)" do
      now = DateTime.utc_now()

      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
            "supply": 300000000,
            "name": "My NFT",
            "type": "non-fungible",
            "symbol": "MNFT",
            "properties": {
               "description": "this property is for all NFT"
            },
            "collection": [
               { "image": "link of the 1st NFT image" },
               { "image": "link of the 2nd NFT image" },
               {
                  "image": "link of the 3rd NFT image",
                  "other_property": "other value"
               }
            ]
          }
          """
        )

      tx_address = tx.address

      expected_utxos =
        [
          %UnspentOutput{
            amount: 100_000_000,
            from: tx_address,
            type: {:token, tx_address, 1},
            timestamp: now
          },
          %UnspentOutput{
            amount: 100_000_000,
            from: tx_address,
            type: {:token, tx_address, 2},
            timestamp: now
          },
          %UnspentOutput{
            amount: 100_000_000,
            from: tx_address,
            type: {:token, tx_address, 3},
            timestamp: now
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      assert %LedgerValidation{minted_utxos: ^expected_utxos} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
    end

    test "should return an empty list if amount is incorrect (for non-fungible)" do
      now = DateTime.utc_now()

      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
            "supply": 1,
            "type": "non-fungible",
            "name": "My NFT",
            "symbol": "MNFT",
            "properties": {
               "image": "base64 of the image",
               "description": "This is a NFT with an image"
            }
          }
          """
        )

      assert %LedgerValidation{minted_utxos: []} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
    end

    test "should return an empty list if invalid tx" do
      now = DateTime.utc_now()

      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
          "supply": "foo"
          }
          """
        )

      assert %LedgerValidation{minted_utxos: []} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())

      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
          "supply": 100000000
          }
          """
        )

      assert %LedgerValidation{minted_utxos: []} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())

      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
            "type": "fungible"
          }
          """
        )

      assert %LedgerValidation{minted_utxos: []} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
    end
  end

  describe "validate_sufficient_funds/2" do
    setup do
      %{tx: TransactionFactory.create_valid_transaction()}
    end

    test "should raise if not in minted_utxos state" do
      assert_raise FunctionClauseError, fn ->
        %LedgerValidation{} |> LedgerValidation.validate_sufficient_funds([])
      end
    end

    test "should update state to sufficient_funds_validated", %{tx: tx} do
      assert %LedgerValidation{state: :sufficient_funds_validated} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(
                 tx,
                 DateTime.utc_now(),
                 current_protocol_version()
               )
               |> LedgerValidation.validate_sufficient_funds([])
    end

    test "should set the movement in the struct", %{tx: tx} do
      movements = [
        %TransactionMovement{
          to: "@JeanClaude",
          amount: 100_000_000,
          type: {:token, "@CharlieToken", 0}
        }
      ]

      assert %LedgerValidation{transaction_movements: ^movements} =
               %LedgerValidation{fee: 1_000}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(
                 tx,
                 DateTime.utc_now(),
                 current_protocol_version()
               )
               |> LedgerValidation.validate_sufficient_funds(movements)
    end

    test "should return insufficient funds when not enough uco", %{tx: tx} do
      assert %LedgerValidation{sufficient_funds?: false} =
               %LedgerValidation{fee: 1_000}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(
                 tx,
                 DateTime.utc_now(),
                 current_protocol_version()
               )
               |> LedgerValidation.validate_sufficient_funds([])
    end

    test "should return insufficient funds when not enough tokens", %{tx: tx} do
      inputs = [
        %UnspentOutput{
          from: "@Charlie1",
          amount: 1_000,
          type: :UCO,
          timestamp: ~U[2022-10-09 08:39:10.463Z]
        }
        |> VersionedUnspentOutput.wrap_unspent_output(current_protocol_version())
      ]

      movements = [
        %TransactionMovement{
          to: "@JeanClaude",
          amount: 100_000_000,
          type: {:token, "@CharlieToken", 0}
        }
      ]

      assert %LedgerValidation{sufficient_funds?: false} =
               %LedgerValidation{fee: 1_000}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(
                 tx,
                 DateTime.utc_now(),
                 current_protocol_version()
               )
               |> LedgerValidation.validate_sufficient_funds(movements)
    end

    test "should not be able to pay with the same non-fungible token twice" do
      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
            "supply": 100000000,
            "type": "non-fungible",
            "name": "My NFT",
            "symbol": "MNFT"
          }
          """
        )

      inputs = [
        %UnspentOutput{
          from: "@Charlie1",
          amount: 1_000,
          type: :UCO,
          timestamp: ~U[2022-10-09 08:39:10.463Z]
        }
        |> VersionedUnspentOutput.wrap_unspent_output(current_protocol_version())
      ]

      movements = [
        %TransactionMovement{
          to: "@JeanClaude",
          amount: 100_000_000,
          type: {:token, tx.address, 1}
        },
        %TransactionMovement{
          to: "@JeanBob",
          amount: 100_000_000,
          type: {:token, tx.address, 1}
        }
      ]

      assert %LedgerValidation{sufficient_funds?: false} =
               %LedgerValidation{fee: 1_000}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(
                 tx,
                 DateTime.utc_now(),
                 current_protocol_version()
               )
               |> LedgerValidation.validate_sufficient_funds(movements)
    end

    test "should return available balance and amount to spend and return sufficient_funds to true" do
      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
            "supply": 100000000,
            "type": "non-fungible",
            "name": "My NFT",
            "symbol": "MNFT"
          }
          """
        )

      inputs =
        [
          %UnspentOutput{
            from: "@Charlie1",
            amount: 10_000,
            type: :UCO,
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          },
          %UnspentOutput{
            from: "@Alice",
            amount: 100_000_000,
            type: {:token, "@Token1", 0},
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          },
          %UnspentOutput{
            from: "@Bob",
            amount: 100_100_000,
            type: {:token, "@Token1", 0},
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      movements = [
        %TransactionMovement{
          to: "@JeanClaude",
          amount: 100_000_000,
          type: {:token, tx.address, 1}
        },
        %TransactionMovement{
          to: "@Michel",
          amount: 120_000_000,
          type: {:token, "@Token1", 0}
        },
        %TransactionMovement{
          to: "@Toto",
          amount: 456,
          type: :UCO
        }
      ]

      expected_balance = %{
        uco: 10_000,
        token: %{{"@Token1", 0} => 200_100_000, {tx.address, 1} => 100_000_000}
      }

      expected_amount_to_spend = %{
        uco: 1456,
        token: %{{"@Token1", 0} => 120_000_000, {tx.address, 1} => 100_000_000}
      }

      assert %LedgerValidation{
               sufficient_funds?: true,
               balances: ^expected_balance,
               amount_to_spend: ^expected_amount_to_spend
             } =
               %LedgerValidation{fee: 1_000}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(
                 tx,
                 DateTime.utc_now(),
                 current_protocol_version()
               )
               |> LedgerValidation.validate_sufficient_funds(movements)
    end
  end

  describe "consume_inputs/4" do
    setup do
      %{tx: TransactionFactory.create_valid_transaction()}
    end

    test "should raise if not in sufficient_funds_validated state" do
      assert_raise FunctionClauseError, fn ->
        %LedgerValidation{}
        |> LedgerValidation.consume_inputs(random_address(), DateTime.utc_now())
      end
    end

    test "should update state to inputs_consumed", %{tx: tx} do
      assert %LedgerValidation{state: :inputs_consumed} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(
                 tx,
                 DateTime.utc_now(),
                 current_protocol_version()
               )
               |> LedgerValidation.validate_sufficient_funds([])
               |> LedgerValidation.consume_inputs(random_address(), DateTime.utc_now())
    end

    test "When a single unspent output is sufficient to satisfy the transaction movements", %{
      tx: tx
    } do
      timestamp = ~U[2022-10-10 10:44:38.983Z]
      tx_address = "@Alice2"

      inputs = [
        %UnspentOutput{
          from: "@Bob3",
          amount: 2_000_000_000,
          type: :UCO,
          timestamp: ~U[2022-10-09 08:39:10.463Z]
        }
        |> VersionedUnspentOutput.wrap_unspent_output(current_protocol_version())
      ]

      movements = [
        %TransactionMovement{to: "@Bob4", amount: 1_040_000_000, type: :UCO},
        %TransactionMovement{to: "@Charlie2", amount: 217_000_000, type: :UCO}
      ]

      assert %LedgerValidation{
               fee: 40_000_000,
               unspent_outputs: [
                 %UnspentOutput{
                   from: "@Alice2",
                   amount: 703_000_000,
                   type: :UCO,
                   timestamp: ~U[2022-10-10 10:44:38.983Z]
                 }
               ],
               consumed_inputs: [
                 %VersionedUnspentOutput{
                   unspent_output: %UnspentOutput{
                     from: "@Bob3",
                     amount: 2_000_000_000,
                     type: :UCO,
                     timestamp: ~U[2022-10-09 08:39:10.463Z]
                   }
                 }
               ]
             } =
               %LedgerValidation{fee: 40_000_000}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(tx, timestamp, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds(movements)
               |> LedgerValidation.consume_inputs(tx_address, timestamp)
    end

    test "When multiple little unspent output are sufficient to satisfy the transaction movements",
         %{tx: tx} do
      tx_address = "@Alice2"
      timestamp = ~U[2022-10-10 10:44:38.983Z]

      inputs =
        [
          %UnspentOutput{
            from: "@Bob3",
            amount: 500_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          },
          %UnspentOutput{
            from: "@Tom4",
            amount: 700_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          },
          %UnspentOutput{
            from: "@Christina",
            amount: 400_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          },
          %UnspentOutput{
            from: "@Hugo",
            amount: 800_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      movements = [
        %TransactionMovement{to: "@Bob4", amount: 1_040_000_000, type: :UCO},
        %TransactionMovement{to: "@Charlie2", amount: 217_000_000, type: :UCO}
      ]

      expected_consumed_inputs =
        [
          %UnspentOutput{
            from: "@Bob3",
            amount: 500_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          },
          %UnspentOutput{
            from: "@Christina",
            amount: 400_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          },
          %UnspentOutput{
            from: "@Hugo",
            amount: 800_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          },
          %UnspentOutput{
            from: "@Tom4",
            amount: 700_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      assert %LedgerValidation{
               fee: 40_000_000,
               unspent_outputs: [
                 %UnspentOutput{
                   from: "@Alice2",
                   amount: 1_103_000_000,
                   type: :UCO,
                   timestamp: ~U[2022-10-10 10:44:38.983Z]
                 }
               ],
               consumed_inputs: ^expected_consumed_inputs
             } =
               %LedgerValidation{fee: 40_000_000}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(tx, timestamp, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds(movements)
               |> LedgerValidation.consume_inputs(tx_address, timestamp)
    end

    test "When using Token unspent outputs are sufficient to satisfy the transaction movements",
         %{tx: tx} do
      tx_address = "@Alice2"
      timestamp = ~U[2022-10-10 10:44:38.983Z]

      inputs =
        [
          %UnspentOutput{
            from: "@Charlie1",
            amount: 200_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          },
          %UnspentOutput{
            from: "@Bob3",
            amount: 1_200_000_000,
            type: {:token, "@CharlieToken", 0},
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      movements = [
        %TransactionMovement{
          to: "@Bob4",
          amount: 1_000_000_000,
          type: {:token, "@CharlieToken", 0}
        }
      ]

      expected_consumed_inputs =
        [
          %UnspentOutput{
            from: "@Charlie1",
            amount: 200_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          },
          %UnspentOutput{
            from: "@Bob3",
            amount: 1_200_000_000,
            type: {:token, "@CharlieToken", 0},
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      assert %LedgerValidation{
               fee: 40_000_000,
               unspent_outputs: [
                 %UnspentOutput{
                   from: "@Alice2",
                   amount: 160_000_000,
                   type: :UCO,
                   timestamp: ~U[2022-10-10 10:44:38.983Z]
                 },
                 %UnspentOutput{
                   from: "@Alice2",
                   amount: 200_000_000,
                   type: {:token, "@CharlieToken", 0},
                   timestamp: ~U[2022-10-10 10:44:38.983Z]
                 }
               ],
               consumed_inputs: ^expected_consumed_inputs
             } =
               %LedgerValidation{fee: 40_000_000}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(tx, timestamp, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds(movements)
               |> LedgerValidation.consume_inputs(tx_address, timestamp)
    end

    test "When multiple Token unspent outputs are sufficient to satisfy the transaction movements",
         %{tx: tx} do
      tx_address = "@Alice2"
      timestamp = ~U[2022-10-10 10:44:38.983Z]

      inputs =
        [
          %UnspentOutput{
            from: "@Charlie1",
            amount: 200_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          },
          %UnspentOutput{
            from: "@Bob3",
            amount: 500_000_000,
            type: {:token, "@CharlieToken", 0},
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          },
          %UnspentOutput{
            from: "@Hugo5",
            amount: 700_000_000,
            type: {:token, "@CharlieToken", 0},
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          },
          %UnspentOutput{
            from: "@Tom1",
            amount: 700_000_000,
            type: {:token, "@CharlieToken", 0},
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      movements = [
        %TransactionMovement{
          to: "@Bob4",
          amount: 1_000_000_000,
          type: {:token, "@CharlieToken", 0}
        }
      ]

      expected_consumed_inputs =
        [
          %UnspentOutput{
            from: "@Charlie1",
            amount: 200_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          },
          %UnspentOutput{
            from: "@Bob3",
            amount: 500_000_000,
            type: {:token, "@CharlieToken", 0},
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          },
          %UnspentOutput{
            from: "@Hugo5",
            amount: 700_000_000,
            type: {:token, "@CharlieToken", 0},
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          },
          %UnspentOutput{
            amount: 700_000_000,
            from: "@Tom1",
            type: {:token, "@CharlieToken", 0},
            timestamp: ~U[2022-10-10 10:44:38.983Z]
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      assert %LedgerValidation{
               fee: 40_000_000,
               unspent_outputs: [
                 %UnspentOutput{
                   from: "@Alice2",
                   amount: 160_000_000,
                   type: :UCO,
                   timestamp: ~U[2022-10-10 10:44:38.983Z]
                 },
                 %UnspentOutput{
                   from: "@Alice2",
                   amount: 900_000_000,
                   type: {:token, "@CharlieToken", 0},
                   timestamp: ~U[2022-10-10 10:44:38.983Z]
                 }
               ],
               consumed_inputs: ^expected_consumed_inputs
             } =
               %LedgerValidation{fee: 40_000_000}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(tx, timestamp, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds(movements)
               |> LedgerValidation.consume_inputs(tx_address, timestamp)
    end

    test "When non-fungible tokens are used as input but want to consume only a single input", %{
      tx: tx
    } do
      tx_address = "@Alice2"
      timestamp = ~U[2022-10-10 10:44:38.983Z]

      inputs =
        [
          %UnspentOutput{
            from: "@Charlie1",
            amount: 200_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          },
          %UnspentOutput{
            from: "@CharlieToken",
            amount: 100_000_000,
            type: {:token, "@CharlieToken", 1},
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          },
          %UnspentOutput{
            from: "@CharlieToken",
            amount: 100_000_000,
            type: {:token, "@CharlieToken", 2},
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          },
          %UnspentOutput{
            from: "@CharlieToken",
            amount: 100_000_000,
            type: {:token, "@CharlieToken", 3},
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      movements = [
        %TransactionMovement{
          to: "@Bob4",
          amount: 100_000_000,
          type: {:token, "@CharlieToken", 2}
        }
      ]

      expected_consumed_inputs =
        [
          %UnspentOutput{
            from: "@Charlie1",
            amount: 200_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          },
          %UnspentOutput{
            from: "@CharlieToken",
            amount: 100_000_000,
            type: {:token, "@CharlieToken", 2},
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      assert %LedgerValidation{
               fee: 40_000_000,
               unspent_outputs: [
                 %UnspentOutput{
                   from: "@Alice2",
                   amount: 160_000_000,
                   type: :UCO,
                   timestamp: ~U[2022-10-10 10:44:38.983Z]
                 }
               ],
               consumed_inputs: ^expected_consumed_inputs
             } =
               %LedgerValidation{fee: 40_000_000}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(tx, timestamp, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds(movements)
               |> LedgerValidation.consume_inputs(tx_address, timestamp)
    end

    test "should be able to pay with the minted fungible tokens" do
      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
            "supply": 100000000,
            "type": "fungible",
            "name": "My NFT",
            "symbol": "MNFT"
          }
          """
        )

      tx_address = tx.address
      now = DateTime.utc_now()

      inputs = [
        %UnspentOutput{
          from: "@Charlie1",
          amount: 1_000,
          type: :UCO,
          timestamp: ~U[2022-10-09 08:39:10.463Z]
        }
        |> VersionedUnspentOutput.wrap_unspent_output(current_protocol_version())
      ]

      movements = [
        %TransactionMovement{
          to: "@JeanClaude",
          amount: 50_000_000,
          type: {:token, tx_address, 0}
        }
      ]

      assert ops_result =
               %LedgerValidation{fee: 1_000}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds(movements)
               |> LedgerValidation.consume_inputs(tx_address, now)

      assert [
               %UnspentOutput{
                 from: ^tx_address,
                 amount: 50_000_000,
                 type: {:token, ^tx_address, 0},
                 timestamp: ^now
               }
             ] = ops_result.unspent_outputs

      burn_address = LedgerValidation.burning_address()

      assert [
               %UnspentOutput{
                 from: "@Charlie1",
                 amount: 1_000,
                 type: :UCO,
                 timestamp: ~U[2022-10-09 08:39:10.463Z]
               },
               %UnspentOutput{
                 from: ^burn_address,
                 amount: 100_000_000,
                 type: {:token, ^tx_address, 0},
                 timestamp: ^now
               }
             ] = ops_result.consumed_inputs |> VersionedUnspentOutput.unwrap_unspent_outputs()
    end

    test "should be able to pay with the minted non-fungible tokens" do
      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
            "supply": 100000000,
            "type": "non-fungible",
            "name": "My NFT",
            "symbol": "MNFT"
          }
          """
        )

      tx_address = tx.address
      now = DateTime.utc_now()

      inputs = [
        %UnspentOutput{
          from: "@Charlie1",
          amount: 1_000,
          type: :UCO,
          timestamp: ~U[2022-10-09 08:39:10.463Z]
        }
        |> VersionedUnspentOutput.wrap_unspent_output(current_protocol_version())
      ]

      movements = [
        %TransactionMovement{
          to: "@JeanClaude",
          amount: 100_000_000,
          type: {:token, tx_address, 1}
        }
      ]

      assert ops_result =
               %LedgerValidation{fee: 1_000}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds(movements)
               |> LedgerValidation.consume_inputs(tx_address, now)

      assert [] = ops_result.unspent_outputs

      burn_address = LedgerValidation.burning_address()

      assert [
               %UnspentOutput{
                 from: "@Charlie1",
                 amount: 1_000,
                 type: :UCO,
                 timestamp: ~U[2022-10-09 08:39:10.463Z]
               },
               %UnspentOutput{
                 from: ^burn_address,
                 amount: 100_000_000,
                 type: {:token, ^tx_address, 1},
                 timestamp: ^now
               }
             ] = ops_result.consumed_inputs |> VersionedUnspentOutput.unwrap_unspent_outputs()
    end

    test "should be able to pay with the minted non-fungible tokens (collection)" do
      tx =
        TransactionFactory.create_valid_transaction([],
          type: :token,
          content: """
          {
            "supply": 200000000,
            "name": "My NFT",
            "type": "non-fungible",
            "symbol": "MNFT",
            "properties": {
               "description": "this property is for all NFT"
            },
            "collection": [
               { "image": "link of the 1st NFT image" },
               { "image": "link of the 2nd NFT image" }
            ]
          }
          """
        )

      tx_address = tx.address
      now = DateTime.utc_now()

      inputs = [
        %UnspentOutput{
          from: "@Charlie1",
          amount: 1_000,
          type: :UCO,
          timestamp: ~U[2022-10-09 08:39:10.463Z]
        }
        |> VersionedUnspentOutput.wrap_unspent_output(current_protocol_version())
      ]

      movements = [
        %TransactionMovement{
          to: "@JeanClaude",
          amount: 100_000_000,
          type: {:token, tx_address, 2}
        }
      ]

      assert ops_result =
               %LedgerValidation{fee: 1_000}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds(movements)
               |> LedgerValidation.consume_inputs(tx_address, now)

      assert [
               %UnspentOutput{
                 from: ^tx_address,
                 amount: 100_000_000,
                 type: {:token, ^tx_address, 1},
                 timestamp: ^now
               }
             ] = ops_result.unspent_outputs

      burn_address = LedgerValidation.burning_address()

      assert [
               %UnspentOutput{
                 from: "@Charlie1",
                 amount: 1_000,
                 type: :UCO,
                 timestamp: ~U[2022-10-09 08:39:10.463Z]
               },
               %UnspentOutput{
                 from: ^burn_address,
                 amount: 100_000_000,
                 type: {:token, ^tx_address, 2},
                 timestamp: ^now
               }
             ] = ops_result.consumed_inputs |> VersionedUnspentOutput.unwrap_unspent_outputs()
    end

    test "should merge two similar tokens and update the from & timestamp", %{tx: tx} do
      transaction_address = random_address()
      transaction_timestamp = DateTime.utc_now()

      from = random_address()
      token_address = random_address()
      old_timestamp = ~U[2023-11-09 10:39:10Z]

      inputs =
        [
          %UnspentOutput{
            from: from,
            amount: 200_000_000,
            type: :UCO,
            timestamp: old_timestamp
          },
          %UnspentOutput{
            from: from,
            amount: 100_000_000,
            type: {:token, token_address, 0},
            timestamp: old_timestamp
          },
          %UnspentOutput{
            from: from,
            amount: 100_000_000,
            type: {:token, token_address, 0},
            timestamp: old_timestamp
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      expected_consumed_inputs =
        [
          %UnspentOutput{
            from: from,
            amount: 200_000_000,
            type: :UCO,
            timestamp: old_timestamp
          },
          %UnspentOutput{
            from: from,
            amount: 100_000_000,
            type: {:token, token_address, 0},
            timestamp: old_timestamp
          },
          %UnspentOutput{
            from: from,
            amount: 100_000_000,
            type: {:token, token_address, 0},
            timestamp: old_timestamp
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      assert %LedgerValidation{
               unspent_outputs: [
                 %UnspentOutput{
                   from: ^transaction_address,
                   amount: 160_000_000,
                   type: :UCO,
                   timestamp: ^transaction_timestamp
                 },
                 %UnspentOutput{
                   from: ^transaction_address,
                   amount: 200_000_000,
                   type: {:token, ^token_address, 0},
                   timestamp: ^transaction_timestamp
                 }
               ],
               consumed_inputs: ^expected_consumed_inputs,
               fee: 40_000_000
             } =
               %LedgerValidation{fee: 40_000_000}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(
                 tx,
                 transaction_timestamp,
                 current_protocol_version()
               )
               |> LedgerValidation.validate_sufficient_funds([])
               |> LedgerValidation.consume_inputs(transaction_address, transaction_timestamp)

      tx_address = "@Alice2"
      now = DateTime.utc_now()

      inputs =
        [
          %UnspentOutput{
            from: "@Charlie1",
            amount: 300_000_000,
            type: {:token, "@Token1", 0},
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          },
          %UnspentOutput{
            from: "@Tom5",
            amount: 300_000_000,
            type: {:token, "@Token1", 0},
            timestamp: ~U[2022-10-20 08:00:20.463Z]
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      movements = [
        %TransactionMovement{
          to: "@Bob3",
          amount: 100_000_000,
          type: {:token, "@Token1", 0}
        }
      ]

      assert %LedgerValidation{
               unspent_outputs: [
                 %UnspentOutput{
                   from: "@Alice2",
                   amount: 500_000_000,
                   type: {:token, "@Token1", 0}
                 }
               ],
               consumed_inputs: [
                 %VersionedUnspentOutput{unspent_output: %UnspentOutput{from: "@Charlie1"}},
                 %VersionedUnspentOutput{unspent_output: %UnspentOutput{from: "@Tom5"}}
               ]
             } =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds(movements)
               |> LedgerValidation.consume_inputs(tx_address, now)
    end

    test "should consume state if it's not the same", %{tx: tx} do
      now = DateTime.utc_now()

      inputs =
        [
          %UnspentOutput{
            type: :state,
            from: random_address(),
            encoded_payload: :crypto.strong_rand_bytes(32),
            timestamp: now
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      new_state = :crypto.strong_rand_bytes(32)

      assert %LedgerValidation{
               consumed_inputs: ^inputs,
               unspent_outputs: [%UnspentOutput{type: :state, encoded_payload: ^new_state}]
             } =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds([])
               |> LedgerValidation.consume_inputs("@Alice2", now, new_state, nil)
    end

    # test "should not consume state if it's the same" do
    #   state = :crypto.strong_rand_bytes(32)
    #
    #   inputs =
    #     [
    #       %UnspentOutput{
    #         type: :state,
    #         from: random_address(),
    #         encoded_payload: state,
    #         timestamp: DateTime.utc_now()
    #       }
    #     ]
    #     |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())
    #
    #   tx_validation_time = DateTime.utc_now()
    #
    #   assert {:ok,
    #           %LedgerValidation{
    #             consumed_inputs: [],
    #             unspent_outputs: []
    #           }} =
    #            LedgerValidation.consume_inputs(
    #              %LedgerValidation{fee: 0},
    #              "@Alice2",
    #              tx_validation_time,
    #              inputs,
    #              [],
    #              [],
    #              state,
    #              nil
    #            )
    # end

    test "should not return any utxo if nothing is spent", %{tx: tx} do
      timestamp = ~U[2022-10-10 10:44:38.983Z]

      inputs = [
        %UnspentOutput{
          from: "@Bob3",
          amount: 2_000_000_000,
          type: :UCO,
          timestamp: timestamp
        }
        |> VersionedUnspentOutput.wrap_unspent_output(current_protocol_version())
      ]

      assert %LedgerValidation{fee: 0, unspent_outputs: [], consumed_inputs: []} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(tx, timestamp, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds([])
               |> LedgerValidation.consume_inputs("@Alice2", timestamp)
    end

    test "should not update utxo if not consumed", %{tx: tx} do
      token_address = random_address()

      utxo_not_used = [
        %UnspentOutput{
          from: random_address(),
          amount: 200_000_000,
          type: :UCO,
          timestamp: ~U[2022-10-09 08:39:10.463Z]
        },
        %UnspentOutput{
          from: random_address(),
          amount: 500_000_000,
          type: {:token, token_address, 0},
          timestamp: ~U[2022-10-09 08:39:10.463Z]
        }
      ]

      consumed_utxo =
        [
          %UnspentOutput{
            from: random_address(),
            amount: 700_000_000,
            type: {:token, token_address, 0},
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          },
          %UnspentOutput{
            amount: 700_000_000,
            from: random_address(),
            type: {:token, token_address, 0},
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      all_utxos =
        VersionedUnspentOutput.wrap_unspent_outputs(utxo_not_used, current_protocol_version()) ++
          consumed_utxo

      movements = [
        %TransactionMovement{
          to: random_address(),
          amount: 1_400_000_000,
          type: {:token, token_address, 0}
        }
      ]

      timestamp = ~U[2022-10-10 10:44:38.983Z]

      assert %LedgerValidation{fee: 0, unspent_outputs: [], consumed_inputs: consumed_inputs} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs(all_utxos, nil)
               |> LedgerValidation.mint_token_utxos(tx, timestamp, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds(movements)
               |> LedgerValidation.consume_inputs(random_address(), timestamp)

      # order does not matter
      assert Enum.all?(consumed_inputs, &(&1 in consumed_utxo)) and
               length(consumed_inputs) == length(consumed_utxo)
    end

    test "should optimize consumed utxo to avoid consolidation", %{tx: tx} do
      optimized_utxo = [
        %UnspentOutput{
          from: random_address(),
          amount: 200_000_000,
          type: :UCO,
          timestamp: ~U[2022-10-09 08:39:10.463Z]
        }
      ]

      consumed_utxo =
        [
          %UnspentOutput{
            from: random_address(),
            amount: 10_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          },
          %UnspentOutput{
            from: random_address(),
            amount: 40_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          },
          %UnspentOutput{
            from: random_address(),
            amount: 150_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      all_utxos =
        VersionedUnspentOutput.wrap_unspent_outputs(optimized_utxo, current_protocol_version()) ++
          consumed_utxo

      movements = [%TransactionMovement{to: random_address(), amount: 200_000_000, type: :UCO}]

      timestamp = ~U[2022-10-10 10:44:38.983Z]

      assert %LedgerValidation{fee: 0, unspent_outputs: [], consumed_inputs: consumed_inputs} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs(all_utxos, nil)
               |> LedgerValidation.mint_token_utxos(tx, timestamp, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds(movements)
               |> LedgerValidation.consume_inputs(random_address(), timestamp)

      # order does not matter
      assert Enum.all?(consumed_inputs, &(&1 in consumed_utxo)) and
               length(consumed_inputs) == length(consumed_utxo)
    end

    test "should sort utxo to be consistent across nodes", %{tx: tx} do
      [lower_address, higher_address] = [random_address(), random_address()] |> Enum.sort()

      optimized_utxo = [
        %UnspentOutput{
          from: lower_address,
          amount: 150_000_000,
          type: :UCO,
          timestamp: ~U[2022-10-09 08:39:07.463Z]
        }
      ]

      consumed_utxo =
        [
          %UnspentOutput{
            from: random_address(),
            amount: 10_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-09 08:39:00.463Z]
          },
          %UnspentOutput{
            from: higher_address,
            amount: 150_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-09 08:39:07.463Z]
          },
          %UnspentOutput{
            from: random_address(),
            amount: 150_000_000,
            type: :UCO,
            timestamp: ~U[2022-10-09 08:39:10.463Z]
          }
        ]
        |> VersionedUnspentOutput.wrap_unspent_outputs(current_protocol_version())

      all_utxo =
        VersionedUnspentOutput.wrap_unspent_outputs(optimized_utxo, current_protocol_version()) ++
          consumed_utxo

      movements = [%TransactionMovement{to: random_address(), amount: 310_000_000, type: :UCO}]

      timestamp = ~U[2022-10-10 10:44:38.983Z]

      Enum.each(1..5, fn _ ->
        randomized_utxo = Enum.shuffle(all_utxo)

        assert %LedgerValidation{fee: 0, unspent_outputs: [], consumed_inputs: consumed_inputs} =
                 %LedgerValidation{}
                 |> LedgerValidation.filter_usable_inputs(randomized_utxo, nil)
                 |> LedgerValidation.mint_token_utxos(tx, timestamp, current_protocol_version())
                 |> LedgerValidation.validate_sufficient_funds(movements)
                 |> LedgerValidation.consume_inputs(random_address(), timestamp)

        # order does not matter
        assert Enum.all?(consumed_inputs, &(&1 in consumed_utxo)) and
                 length(consumed_inputs) == length(consumed_utxo)
      end)
    end
  end

  describe "build_resoved_movements/3" do
    setup do
      %{tx: TransactionFactory.create_valid_transaction()}
    end

    test "should raise if not in inputs_consumed state" do
      assert_raise FunctionClauseError, fn ->
        %LedgerValidation{} |> LedgerValidation.build_resolved_movements(%{}, :transfer)
      end
    end

    test "should update state to movements_resolved", %{tx: tx} do
      now = DateTime.utc_now()

      assert %LedgerValidation{state: :movements_resolved} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds([])
               |> LedgerValidation.consume_inputs(random_address(), now)
               |> LedgerValidation.build_resolved_movements(%{}, :transfer)
    end

    test "should resolve, convert reward and aggregate movements", %{tx: tx} do
      now = DateTime.utc_now()

      address1 = random_address()
      address2 = random_address()

      resolved_address1 = random_address()
      resolved_address2 = random_address()

      token_address = random_address()
      reward_token_address = random_address()

      resolved_addresses = %{address1 => resolved_address1, address2 => resolved_address2}

      RewardTokens.add_reward_token_address(reward_token_address)

      movements = [
        %TransactionMovement{to: address1, amount: 10, type: :UCO},
        %TransactionMovement{to: address1, amount: 10, type: {:token, token_address, 0}},
        %TransactionMovement{to: address1, amount: 40, type: {:token, token_address, 0}},
        %TransactionMovement{to: address2, amount: 30, type: {:token, reward_token_address, 0}},
        %TransactionMovement{to: address1, amount: 50, type: {:token, reward_token_address, 0}}
      ]

      expected_resolved_movement = [
        %TransactionMovement{to: resolved_address1, amount: 60, type: :UCO},
        %TransactionMovement{to: resolved_address1, amount: 50, type: {:token, token_address, 0}},
        %TransactionMovement{to: resolved_address2, amount: 30, type: :UCO}
      ]

      assert %LedgerValidation{transaction_movements: resolved_movements} =
               %LedgerValidation{}
               |> LedgerValidation.filter_usable_inputs([], nil)
               |> LedgerValidation.mint_token_utxos(tx, now, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds(movements)
               |> LedgerValidation.consume_inputs(random_address(), now)
               |> LedgerValidation.build_resolved_movements(resolved_addresses, :transfer)

      # Order does not matters
      assert length(expected_resolved_movement) == length(resolved_movements)
      assert Enum.all?(expected_resolved_movement, &Enum.member?(resolved_movements, &1))
    end
  end

  describe "to_ledger_operations/1" do
    setup do
      %{tx: TransactionFactory.create_valid_transaction()}
    end

    test "should raise if not in inputs_consumed state" do
      assert_raise FunctionClauseError, fn ->
        %LedgerValidation{} |> LedgerValidation.to_ledger_operations()
      end
    end

    test "should return LegderOperations struct", %{tx: tx} do
      timestamp = ~U[2022-10-10 10:44:38.983Z]
      tx_address = "@Alice2"

      inputs = [
        %UnspentOutput{
          from: "@Bob3",
          amount: 2_000_000_000,
          type: :UCO,
          timestamp: ~U[2022-10-09 08:39:10.463Z]
        }
        |> VersionedUnspentOutput.wrap_unspent_output(current_protocol_version())
      ]

      movements = [
        %TransactionMovement{to: "@Bob4", amount: 1_040_000_000, type: :UCO},
        %TransactionMovement{to: "@Charlie2", amount: 217_000_000, type: :UCO}
      ]

      resolved_addresses = Enum.map(movements, &{&1.to, &1.to}) |> Map.new()

      assert %LedgerOperations{
               fee: 40_000_000,
               unspent_outputs: [
                 %UnspentOutput{
                   from: "@Alice2",
                   amount: 703_000_000,
                   type: :UCO,
                   timestamp: ~U[2022-10-10 10:44:38.983Z]
                 }
               ],
               consumed_inputs: ^inputs,
               transaction_movements: ^movements
             } =
               %LedgerValidation{fee: 40_000_000}
               |> LedgerValidation.filter_usable_inputs(inputs, nil)
               |> LedgerValidation.mint_token_utxos(tx, timestamp, current_protocol_version())
               |> LedgerValidation.validate_sufficient_funds(movements)
               |> LedgerValidation.consume_inputs(tx_address, timestamp)
               |> LedgerValidation.build_resolved_movements(resolved_addresses, :transfer)
               |> LedgerValidation.to_ledger_operations()
    end
  end
end
