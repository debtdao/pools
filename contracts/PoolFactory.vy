# @version ^0.3.7

struct Fees: # from PoolDelegate.vy
	performance: uint16
	deposit: uint16
	withdraw: uint16
	flash: uint16
	collector: uint16
	referral: uint16

interface Oracle:
    def getLatestAnswer(token: address) -> uint256: nonpayable

MAX_TOKEN_PER_CLASS: constant(uint256) = 10

NUM_ETHLIKECOINS: public(uint256)
ETHLIKE_COINS: public(address[MAX_TOKEN_PER_CLASS])

NUM_SHITCOINS: public(uint256)
USD_SHITCOINS: public(address[MAX_TOKEN_PER_CLASS])

# CRV_BASE_USD_POOL: constant(address) = convert("0x6b175474e89094c44da98b954eedeac495271d0f", address)
CRV_BASE_USD_POOL: constant(address) = 0x6B175474E89094C44Da98b954EedeAC495271d0F
# CRV_BASE_USD_POOL: constant(address) = address("0x6b175474e89094c44da98b954eedeac495271d0f")

oracle: public(immutable(Oracle))

pool_implementation: public(immutable(address))
bond_token_implementation: public(immutable(address))
chicken_bond_implementation: public(immutable(address))

@external
def __init__(pool_impl: address, bond_token_impl: address, chicken_impl: address, oracle_: address,
            eth_coins: DynArray[address, MAX_TOKEN_PER_CLASS], usd_coins: DynArray[address, MAX_TOKEN_PER_CLASS]):
    """
    @dev    MUST ensure `pool_imoplementation` was deployed properly.
            MUST follow instructions at https://github.com/vyperlang/vyper/blob/2adc34ffd3bee8b6dee90f552bbd9bb844509e19/tests/base_conftest.py#L130-L160
    @param pool_impl    Debt DAO Pool logic
    @param chicken_impl Debt DAO Pool Chicken Bond Factory contract to create bonds for credit pools
    
    """
    pool_implementation = pool_impl
    bond_token_implementation = bond_token_impl
    chicken_bond_implementation = chicken_impl

    ETHLIKE_COINS = eth_coins
    NUM_ETHLIKECOINS = len(eth_coins)
    USDLIKE_COINS = usd_coins
    NUM_USDLIKECOINS = len(usd_coins)

    oracle = Oracle(oracle_)

@external
def deploy_pool(owner: address, token: address, name: String[50], symbol: String[18], fees: Fees) -> address:
    assert oracle.getLatestAnswer(token) != 0

    # https://vyper.readthedocs.io/en/latest/built-in-functions.html?highlight=create_from_blueprint#create_from_blueprint
    pool: address = create_from_blueprint(
        pool_implementation,
        owner,
        token,
        name,
        symbol,
        fees,
        code_offset=0, # tbh dont know what this does
        salt=keccak256(_abi_encode(self, msg.sender, token)) # similiar composite index as lines for pool CREATE2. (contract-actor-token)
    )

    self._deplot_ze_chikkins(pool, token)

    return pool

@internal
def _deplot_ze_chikkins(pool: address, token: address) -> address:
    """
    @notice         the plot thickens with another chicken. May your bonds be forever unbroken
    @param pool     pool to deploy chicken bond for
    @param token    token that pool and chicjken bond are denominated in
    """

    # deploy bddp token
    bddp_token: address = create_from_blueprint(
        bond_token_impl,
        code_offset=0, # tbh dont know what this does
        salt=keccak256(_abi_encode(pool, self, token)) # similiar composite index as lines for chicken_factory CREATE2. (contract-actor-token)
    )

    # https://vyper.readthedocs.io/en/latest/built-in-functions.html?highlight=create_from_blueprint#create_from_blueprint
    chicken_factory: address = create_from_blueprint(
        code_offset=0, # tbh dont know what this does
        salt=keccak256(_abi_encode(bddp_token, self, token)) # similiar composite index as lines for chicken_factory CREATE2. (contract-actor-token)
    )

    self._compute_and_deploy_crv_pools()

    # deploy chicken bond for new chicken_factory

    return chicken_factory

@internal
def _compute_and_deploy_crv_pools(bddp_token: address, ddp_token: address, base_token: address, ) -> address:
    """
    @notice         the plot thickens with another chicken. May your bonds be forever unbroken
    @param pool     pool to deploy chicken bond for
    @param token    token that pool and chicjken bond are denominated in
    """
    # https://vyper.readthedocs.io/en/latest/built-in-functions.html?highlight=create_from_blueprint#create_from_blueprint
    chicken_factory: address = create_from_blueprint(
        code_offset=0, # tbh dont know what this does
        salt=keccak256(_abi_encode(pool, self, token)) # similiar composite index as lines for chicken_factory CREATE2. (contract-actor-token)
    )

    # deploy chicken bond for new chicken_factory

    return chicken_factory

@internal
def _get_base_pool_for_base_toke (base_token: address, ) -> address:
    """
    @notice         the plot thickens with another chicken. May your bonds be forever unbroken
    @param base_tokem   raw asset that 
    @param token    token that pool and chicjken bond are denominated in
    """
    if base_token in USD_SHITCOINS:
        return CRV_BASE_3POOL




# fin




# much empty
# fuck around and throw some NFT shit in here?





