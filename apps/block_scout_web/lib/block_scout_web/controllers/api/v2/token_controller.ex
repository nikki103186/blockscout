defmodule BlockScoutWeb.API.V2.TokenController do
  use BlockScoutWeb, :controller

  alias BlockScoutWeb.AccessHelper
  alias BlockScoutWeb.API.V2.{AddressView, TransactionView}
  alias Explorer.{Chain, Repo}
  alias Explorer.Chain.{Address, BridgedToken, Token, Token.Instance}
  alias Indexer.Fetcher.OnDemand.TokenTotalSupply, as: TokenTotalSupplyOnDemand

  import BlockScoutWeb.Chain,
    only: [
      split_list_by_page: 1,
      paging_options: 1,
      next_page_params: 3,
      token_transfers_next_page_params: 3,
      unique_tokens_paging_options: 1,
      unique_tokens_next_page: 3
    ]

  import BlockScoutWeb.PagingHelper,
    only: [
      chain_ids_filter_options: 1,
      delete_parameters_from_next_page_params: 1,
      token_transfers_types_options: 1,
      tokens_sorting: 1
    ]

  import Explorer.MicroserviceInterfaces.BENS, only: [maybe_preload_ens: 1]
  import Explorer.MicroserviceInterfaces.Metadata, only: [maybe_preload_metadata: 1]

  action_fallback(BlockScoutWeb.API.V2.FallbackController)

  @api_true [api?: true]

  def token(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params),
         {:not_found, {:ok, token}} <- {:not_found, Chain.token_from_address_hash(address_hash, @api_true)} do
      TokenTotalSupplyOnDemand.trigger_fetch(address_hash)

      conn
      |> token_response(token, address_hash)
    end
  end

  if Application.compile_env(:explorer, Explorer.Chain.BridgedToken)[:enabled] do
    defp token_response(conn, token, address_hash) do
      if token.bridged do
        bridged_token = Repo.get_by(BridgedToken, home_token_contract_address_hash: address_hash)

        conn
        |> put_status(200)
        |> render(:bridged_token, %{token: {token, bridged_token}})
      else
        conn
        |> put_status(200)
        |> render(:token, %{token: token})
      end
    end
  else
    defp token_response(conn, token, _address_hash) do
      conn
      |> put_status(200)
      |> render(:token, %{token: token})
    end
  end

  def counters(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params),
         {:not_found, true} <- {:not_found, Chain.token_from_address_hash_exists?(address_hash, @api_true)} do
      {transfer_count, token_holder_count} = Chain.fetch_token_counters(address_hash, 30_000)

      json(conn, %{transfers_count: to_string(transfer_count), token_holders_count: to_string(token_holder_count)})
    end
  end

  def transfers(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params),
         {:not_found, true} <- {:not_found, Chain.token_from_address_hash_exists?(address_hash, @api_true)} do
      paging_options = paging_options(params)

      results =
        address_hash
        |> Chain.fetch_token_transfers_from_token_hash(Keyword.merge(@api_true, paging_options))
        |> Chain.flat_1155_batch_token_transfers()
        |> Chain.paginate_1155_batch_token_transfers(paging_options)

      {token_transfers, next_page} = split_list_by_page(results)

      next_page_params =
        next_page
        |> token_transfers_next_page_params(token_transfers, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> put_view(TransactionView)
      |> render(:token_transfers, %{
        token_transfers: token_transfers |> maybe_preload_ens() |> maybe_preload_metadata(),
        next_page_params: next_page_params
      })
    end
  end

  def holders(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params),
         {:not_found, {:ok, token}} <- {:not_found, Chain.token_from_address_hash(address_hash, @api_true)} do
      results_plus_one =
        Chain.fetch_token_holders_from_token_hash(address_hash, Keyword.merge(paging_options(params), @api_true))

      {token_balances, next_page} = split_list_by_page(results_plus_one)

      next_page_params = next_page |> next_page_params(token_balances, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> render(:token_balances, %{
        token_balances: token_balances |> maybe_preload_ens() |> maybe_preload_metadata(),
        next_page_params: next_page_params,
        token: token
      })
    end
  end

  def instances(
        conn,
        %{"address_hash_param" => address_hash_string, "holder_address_hash" => holder_address_hash_string} = params
      ) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params),
         {:not_found, {:ok, token}} <- {:not_found, Chain.token_from_address_hash(address_hash, @api_true)},
         {:not_found, false} <- {:not_found, Chain.erc_20_token?(token)},
         {:format, {:ok, holder_address_hash}} <- {:format, Chain.string_to_address_hash(holder_address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(holder_address_hash_string, params) do
      holder_address = %Address{Repo.get_by(Address, hash: holder_address_hash) | proxy_implementations: nil}

      results_plus_one =
        Instance.token_instances_by_holder_address_hash(
          token,
          holder_address_hash,
          params
          |> unique_tokens_paging_options()
          |> Keyword.merge(@api_true)
        )

      {token_instances, next_page} = split_list_by_page(results_plus_one)

      next_page_params =
        next_page |> unique_tokens_next_page(token_instances, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> put_view(AddressView)
      |> render(:nft_list, %{
        token_instances: token_instances |> put_owner(holder_address),
        next_page_params: next_page_params,
        token: token
      })
    end
  end

  def instances(conn, %{"address_hash_param" => address_hash_string} = params) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params),
         {:not_found, {:ok, token}} <- {:not_found, Chain.token_from_address_hash(address_hash, @api_true)} do
      results_plus_one =
        Chain.address_to_unique_tokens(
          token.contract_address_hash,
          token,
          Keyword.merge(unique_tokens_paging_options(params), @api_true)
        )

      {token_instances, next_page} = split_list_by_page(results_plus_one)

      next_page_params =
        next_page |> unique_tokens_next_page(token_instances, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> render(:token_instances, %{token_instances: token_instances, next_page_params: next_page_params, token: token})
    end
  end

  def instance(conn, %{"address_hash_param" => address_hash_string, "token_id" => token_id_str} = params) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params),
         {:not_found, {:ok, token}} <- {:not_found, Chain.token_from_address_hash(address_hash, @api_true)},
         {:not_found, false} <- {:not_found, Chain.erc_20_token?(token)},
         {:format, {token_id, ""}} <- {:format, Integer.parse(token_id_str)} do
      token_instance =
        case Chain.nft_instance_from_token_id_and_token_address(token_id, address_hash, @api_true) do
          {:ok, token_instance} ->
            token_instance
            |> Chain.select_repo(@api_true).preload(:owner)
            |> Chain.put_owner_to_token_instance(token, @api_true)

          {:error, :not_found} ->
            %Instance{
              token_id: Decimal.new(token_id),
              metadata: nil,
              owner: nil,
              token_contract_address_hash: address_hash
            }
            |> Instance.put_is_unique(token, @api_true)
            |> Chain.put_owner_to_token_instance(token, @api_true)
        end

      conn
      |> put_status(200)
      |> render(:token_instance, %{
        token_instance: token_instance,
        token: token
      })
    end
  end

  def transfers_by_instance(conn, %{"address_hash_param" => address_hash_string, "token_id" => token_id_str} = params) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params),
         {:not_found, {:ok, token}} <- {:not_found, Chain.token_from_address_hash(address_hash, @api_true)},
         {:not_found, false} <- {:not_found, Chain.erc_20_token?(token)},
         {:format, {token_id, ""}} <- {:format, Integer.parse(token_id_str)} do
      paging_options = paging_options(params)

      results =
        address_hash
        |> Chain.fetch_token_transfers_from_token_hash_and_token_id(token_id, Keyword.merge(paging_options, @api_true))
        |> Chain.flat_1155_batch_token_transfers(Decimal.new(token_id))
        |> Chain.paginate_1155_batch_token_transfers(paging_options)

      {token_transfers, next_page} = split_list_by_page(results)

      next_page_params =
        next_page
        |> token_transfers_next_page_params(token_transfers, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> put_view(TransactionView)
      |> render(:token_transfers, %{
        token_transfers: token_transfers |> maybe_preload_ens() |> maybe_preload_metadata(),
        next_page_params: next_page_params
      })
    end
  end

  def holders_by_instance(conn, %{"address_hash_param" => address_hash_string, "token_id" => token_id_str} = params) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params),
         {:not_found, {:ok, token}} <- {:not_found, Chain.token_from_address_hash(address_hash, @api_true)},
         {:not_found, false} <- {:not_found, Chain.erc_20_token?(token)},
         {:format, {token_id, ""}} <- {:format, Integer.parse(token_id_str)} do
      paging_options = paging_options(params)

      results =
        Chain.fetch_token_holders_from_token_hash_and_token_id(
          address_hash,
          token_id,
          Keyword.merge(paging_options, @api_true)
        )

      {token_holders, next_page} = split_list_by_page(results)

      next_page_params =
        next_page
        |> next_page_params(token_holders, delete_parameters_from_next_page_params(params))

      conn
      |> put_status(200)
      |> render(:token_balances, %{
        token_balances: token_holders |> maybe_preload_ens() |> maybe_preload_metadata(),
        next_page_params: next_page_params,
        token: token
      })
    end
  end

  def transfers_count_by_instance(
        conn,
        %{"address_hash_param" => address_hash_string, "token_id" => token_id_str} = params
      ) do
    with {:format, {:ok, address_hash}} <- {:format, Chain.string_to_address_hash(address_hash_string)},
         {:ok, false} <- AccessHelper.restricted_access?(address_hash_string, params),
         {:not_found, {:ok, token}} <- {:not_found, Chain.token_from_address_hash(address_hash, @api_true)},
         {:not_found, false} <- {:not_found, Chain.erc_20_token?(token)},
         {:format, {token_id, ""}} <- {:format, Integer.parse(token_id_str)} do
      conn
      |> put_status(200)
      |> json(%{
        transfers_count: Chain.count_token_transfers_from_token_hash_and_token_id(address_hash, token_id, @api_true)
      })
    end
  end

  def tokens_list(conn, params) do
    filter = params["q"]

    options =
      params
      |> paging_options()
      |> Keyword.merge(token_transfers_types_options(params))
      |> Keyword.merge(tokens_sorting(params))
      |> Keyword.merge(@api_true)

    {tokens, next_page} = filter |> Token.list_top(options) |> split_list_by_page()

    next_page_params = next_page |> next_page_params(tokens, delete_parameters_from_next_page_params(params))

    conn
    |> put_status(200)
    |> render(:tokens, %{tokens: tokens, next_page_params: next_page_params})
  end

  def bridged_tokens_list(conn, params) do
    filter = params["q"]

    options =
      params
      |> paging_options()
      |> Keyword.merge(chain_ids_filter_options(params))
      |> Keyword.merge(tokens_sorting(params))
      |> Keyword.merge(@api_true)

    {tokens, next_page} = filter |> BridgedToken.list_top_bridged_tokens(options) |> split_list_by_page()

    next_page_params = next_page |> next_page_params(tokens, delete_parameters_from_next_page_params(params))

    conn
    |> put_status(200)
    |> render(:bridged_tokens, %{tokens: tokens, next_page_params: next_page_params})
  end

  defp put_owner(token_instances, holder_address),
    do: Enum.map(token_instances, fn token_instance -> %Instance{token_instance | owner: holder_address} end)
end
