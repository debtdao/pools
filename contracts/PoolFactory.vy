# @version ^0.3.7


"""
@title 	Debt DAO Lending Pool Factory
@author Kiba Gateaux
@desc 	Tokenized, liquid 4626 pool allowing depositors to collectively lend to Debt DAO Line of Credit contracts
@dev 	Automiatically deploys a chicken bond for each new pool.
"""

struct Fees: # from PoolDelegate.vy
	performance: uint16
	deposit: uint16
	withdraw: uint16
	flash: uint16
	collector: uint16
	referral: uint16

interface Oracle:
    def getLatestAnswer(token: address) -> uint256: nonpayable

interface CurveFactory:
     def deploy_metapool(_base_pool: address, _name: String[32], _symbol: String[10], _coin: address, _A: uint256, _fee: uint256) -> address: nonpayable

interface IERC20:
     def decimals() -> uint8: nonpayable
     def _symbol() -> String[18]: nonpayable

interface ERC4626:
    def deposit(): nonpayable

interface ChickenBond:

    def deposit() : nonpayable


event DeployPool:
    pool: indexed(address)
    delegate: indexed(address)
    token: indexed(address)

event DeployPoolChikkinBondz:
    bond_manager: indexed(address)
    bond_token: indexed(address)

event DeployPoolCrvAMMs:
    bond_crv_pool: indexed(address)
    meta_crv_pool: indexed(address)

event ShitcoinListChanged:
    new_list: DynArray[address, MAX_TOKEN_PER_CLASS]

event EthListChanged:
    new_list: DynArray[address, MAX_TOKEN_PER_CLASS]

# default Debt DAO Pool init config
DEFAULT_REFERRAL_FEE: constant(uint16) = 20 # 20 bps, 0.2% of deposit goes to incentivizing chicken bond liquidity
DEFAULT_FLASH_FEE: constant(uint16) = 5     # 5 bps. 0.05% per flashloan. Similar Aave rate.
# Minimum amounts to instantiate new pool/bond system
MIN_USD_DELEGATE_STAKE: constant(uint256) = 100_000 # deployer must initialize pool with their own stake
MIN_ETH_DELEGATE_STAKE: constant(uint256) = 100     # deployer must initialize pool with their own stake

DEFAULT_CRV_A: constant(uint256) = 6 # A = 6. Not pegged assets
DEFAULT_CRV_FEE: constant(uint256) = 15000000 # 0.15%. 10 decimals
CRV_POOL_FACTORY: constant(address) = 0xB9fC157394Af804a3578134A6585C0dc9cc990d4
CRV_META_POOL_USD: constant(address) = 0xA5407eAE9Ba41422680e2e00537571bcC53efBfD # susdv2 pool
CRV_META_POOL_ETH: constant(address) = 0xc5424B857f758E906013F3555Dad202e4bdB4567 # sETH pool

MAX_TOKEN_PER_CLASS: constant(uint256) = 20

ETHLIKE_COINS: public(DynArray[address, MAX_TOKEN_PER_CLASS])
USD_SHITCOINS: public(DynArray[address, MAX_TOKEN_PER_CLASS])

oracle: public(immutable(Oracle))
god: public(immutable(address))

pool_implementation: public(immutable(address))
bond_token_implementation: public(immutable(address))
chicken_bond_implementation: public(immutable(address))

@external
def __init__(god_: address, pool_impl: address, bond_token_impl: address, chicken_impl: address, oracle_: address,
            eth_coins: DynArray[address, MAX_TOKEN_PER_CLASS], usd_coins: DynArray[address, MAX_TOKEN_PER_CLASS]):
    """
    @dev    MUST ensure `pool_imoplementation` was deployed properly.
            MUST follow instructions at https://github.com/vyperlang/vyper/blob/2adc34ffd3bee8b6dee90f552bbd9bb844509e19/tests/base_conftest.py#L130-L160
    @param pool_impl    Debt DAO Pool logic
    @param chicken_impl Debt DAO Pool Chicken Bond Factory contract to create bonds for credit pools
    
    """
    assert god_ != empty(address) # god must not be dead

    god = god_

    pool_implementation = pool_impl
    bond_token_implementation = bond_token_impl
    chicken_bond_implementation = chicken_impl

    self._update_shitcoins(eth_coins)
    self._update_eth_tokens(usd_coins)

    oracle = Oracle(oracle_)

@external
def deploy_pool(_owner: address, _token: address, _name: String[50], _symbol: String[18],
                _performance_fee: uint16, _deposit_fee: uint16, _initial_deposit: uint256) -> address:
    assert oracle.getLatestAnswer(_token) != 0

    fees: Fees = Fees({
        performance: _performance_fee,
        deposit: _deposit_fee,
        withdraw: 0,    # no penalty for withdrawals
        flash: DEFAULT_FLASH_FEE,       # passive income
        collector: 0,   # no automated collections
        referral: DEFAULT_REFERRAL_FEE, # bootstrap bond liquidity
    })

    # https://vyper.readthedocs.io/en/latest/built-in-functions.html?highlight=create_from_blueprint#create_from_blueprint
    pool: address = create_from_blueprint(
        pool_implementation,
        _owner, _token, _name, _symbol, fees, # args
        code_offset=0, # tbh dont know what this does
        salt=keccak256(_abi_encode(self, msg.sender, _token)) # similiar composite index as lines for pool CREATE2. (contract-actor-token)
    )

    log DeployPool(pool, _owner, _token)
    
    if _initial_deposit != 0:
        self._assert_initial_deposit(_token, _initial_deposit)

        manager: address = empty(address)
        bond_token: address = empty(address)
        (manager, bond_token) = self._deplot_ze_chikkins(pool, _token)
        
        base_crv_pool: address = empty(address)
        meta_crv_pool: address = empty(address)
        bond_crv_pool: address = empty(address)
        # pools may be null if deployment wasnt successful
        (base_crv_pool, meta_crv_pool, bond_crv_pool) = self._deploy_crv_pools(_token, pool, bond_token)

        self._seed_all_pools(
            _token, pool, bond_token,
            base_crv_pool, meta_crv_pool, bond_crv_pool,
            manager, _initial_deposit
        )

    return pool

@internal
def _assert_initial_deposit(_base_token: address, _initial_deposit: uint256):
    isUSD: bool = CRV_META_POOL_USD == self._get_meta_pool_for_base_token(_base_token)

    if isUSD:
        assert _initial_deposit >= MIN_USD_DELEGATE_STAKE
    else:
        assert _initial_deposit >= MIN_ETH_DELEGATE_STAKE

    self._erc20_safe_transfer(_base_token, self, _initial_deposit)

@internal
def _erc20_safe_transfer(token: address, receiver: address, amount: uint256):
    response: Bytes[32] = raw_call(
        token,
        concat(
            method_id("transfer(address,uint256)"),
            convert(receiver, bytes32),
            convert(amount, bytes32),
        ),
        max_outsize=32,
		revert_on_failure=True
    )

    if len(response) > 0:
        assert convert(response, bool), "Transfer failed!"



### EVERYTHING BELOW IS NON-ESSENTIAL FUNCTIONALITY

@internal
def _deplot_ze_chikkins(pool: address, base_token: address) -> (address, address):
    """
    @notice         the plot thickens with another chicken. May your bonds be forever unbroken
    @param pool     pool/pool-token to deploy chicken bond for
    @param token    token that pool and chicken bond are denominated in
    """

    # TODO precompute the bddp token address so can ciircular references can be immutable in both contracts
    
    # https://vyper.readthedocs.io/en/latest/built-in-functions.html?highlight=create_from_blueprint#create_from_blueprint
    chikkin_manager: address = create_from_blueprint(
        chicken_bond_implementation,
        code_offset=0, # tbh dont know what this does
        salt=keccak256(_abi_encode(pool)) # similiar composite index as lines for chikkin_manager CREATE2. (contract-actor-token)
    )

    # deploy bddp token
    bddp_token: address = create_from_blueprint(
        bond_token_implementation,
        chikkin_manager,
        code_offset=0, # tbh dont know what this does
        salt=keccak256(_abi_encode(pool)) # similiar composite index as lines for chikkin_manager CREATE2. (contract-actor-token)
    )

    log DeployPoolChikkinBondz(chikkin_manager, bddp_token)

    return (chikkin_manager, bddp_token)

@internal
def _deploy_crv_pools(base_token: address, ddp_token: address, bddp_token: address) -> (address, address, address):
    """
    @notice         The plot thickens with another chicken. May your bonds be forever unbroken
                    Deploys a new CRV pool with ddp + bddp token. Tries to find a base pool to match them with
    @param pool     Pool to deploy chicken bond for
    @param token    Token that pool and chicjken bond are denominated in
    @returns        bond_crv_pool - Pool where newly deployed bond token can be traded.
                    meta_crv_pool - May be null. Crv pool that bond token is paired with for deeper liquidity
    """
    meta_pool: address = self._get_meta_pool_for_base_token(base_token)

    if meta_pool == empty(address):
        # no metapool. create pool with just ddp and bddptokens
        _name: String[32] = "" # TODO
        _symbol: String[10] = "" # TODO
        crv_pool: address = CurveFactory(CRV_POOL_FACTORY).deploy_metapool(meta_pool, _name, _symbol, ddp_token, DEFAULT_CRV_A, DEFAULT_CRV_FEE)

        log DeployPoolCrvAMMs(crv_pool, empty(address))

        return (crv_pool, empty(address), empty(address))
    else:
        _name: String[32] = "" # TODO
        _symbol: String[10] = "" # TODO
        # create metapool with meta_pool and ddp token
        new_meta_pool: address = CurveFactory(CRV_POOL_FACTORY).deploy_metapool(meta_pool, _name, _symbol, ddp_token, DEFAULT_CRV_A, DEFAULT_CRV_FEE)
        # then create another metapool with ddp metapool + bddp token
        bond_pool: address = CurveFactory(CRV_POOL_FACTORY).deploy_metapool(new_meta_pool, _name, _symbol, bddp_token, DEFAULT_CRV_A, DEFAULT_CRV_FEE)

        # @dev MUST call _seed_all_pools after deploying.

        log DeployPoolCrvAMMs(bond_pool, new_meta_pool)

        return (meta_pool, new_meta_pool, bond_pool)

@internal
def _seed_all_pools(base_token: address, ddp_token: address, bddp_token: address, 
                    base_pool: address, ddp_pool: address, bddp_pool: address, 
                    bond_manager: address, initial_deposit: uint256):
    # _assert_initial_deposit must have been called already
    
    # TODO MAJOR problem is u cant immediately mint bddp tokens, it requires bonds to vest. 
    # Add function so that we can immediately mint at slight premium to lowest possible value?
    # might actually support a market price above peg since everyone would arb and we just get more assets permanently in our sysetm


    alloc_per_pool: uint256[12] = [0,0,0,0,0,0,0,0,0,0,0,0]

    if ddp_pool == empty(address):
        # no metapools, just isolated ddp<>bddp pool
        bond_deposit: uint256 = initial_deposit / 2
        # raw_call(bond_manager, )

        # X % - meta pool (mp) - 50% ddp 50% bddp
    

    # 25 % - credit pool (ddp) - 100% bt
    
    # 25 % - base pool (3p) - 100% bt
    
    # 0 % - meta pool (mp) - 50% 3pt, 50% ddpt
    
    # 50 % - bond pool (bp) - 50% bddpt, 50% mpt
    

@view
@internal
def _get_meta_pool_for_base_token(base_token: address, ) -> address:
    """
    @notice         the plot thickens with another chicken. May your bonds be forever unbroken
    @param base_token  raw asset that 
    @param token    token that pool and chicjken bond are denominated in
    """
    if base_token in self.USD_SHITCOINS:
        return CRV_META_POOL_USD

    if base_token in self.ETHLIKE_COINS:
        return CRV_META_POOL_ETH

    return empty(address)

@external
def update_shitcoins(shitcoin_list: DynArray[address, MAX_TOKEN_PER_CLASS]):
    assert msg.sender == god
    self._update_shitcoins(shitcoin_list)

@internal
def _update_shitcoins(shitcoin_list: DynArray[address, MAX_TOKEN_PER_CLASS]):
    self.USD_SHITCOINS = shitcoin_list
    log ShitcoinListChanged(shitcoin_list)

@external
def update_eth_tokens(eth_list: DynArray[address, MAX_TOKEN_PER_CLASS]):
    assert msg.sender == god
    self._update_eth_tokens(eth_list)

@internal
def _update_eth_tokens(eth_list: DynArray[address, MAX_TOKEN_PER_CLASS]):
    self.ETHLIKE_COINS = eth_list
    log EthListChanged(eth_list)


# fin




# much empty
# fuck around and throw some NFT shit in here?





