enum BOND_STATUS:
    NULL
    ACTIVE
    CHIKKIN_OUT
    CHIKKIN_IN


interface IBondManager:
    # // Valid values for `status` returned by `getBondData()`

    def base_token() -> address: nonpayable
    def bond_token() -> address: nonpayable
    def crv_pool() -> address: nonpayable
    
    # // constants
    def INDEX_OF_BASE_TOKEN_IN_CURVE_POOL() -> int128: nonpayable

    # Stndard solidity interface
    def createBond(_lusdAmount: uint256) -> uint256: nonpayable
    def createBondWithPermit(
        owner: address,
        amount: uint256,
        deadline: uint256,
        v: uint8,
        r: bytes32,
        s: bytes32 
    ) -> uint256: nonpayable
    def chickenOut(_bondID: uint256, _minLUSD: uint256): nonpayable
    def chickenIn(_bondID: uint256): nonpayable
    def redeem(_bLUSDToRedeem: uint256, _minLUSDFromBAMMSPVault: uint256) -> (uint256, uint256): nonpayable

    # semantic vyper interface
    def create_bond(_lusdAmount: uint256) -> uint256: nonpayable
    def create_bond_with_permit(
        owner: address,
        amount: uint256,
        deadline: uint256,
        v: uint8,
        r: bytes32,
        s: bytes32 
    ) -> uint256: nonpayable
    def chicken_out(_bondID: uint256, _minLUSD: uint256): nonpayable
    def chicken_in(_bondID: uint256): nonpayable



    # // getters
    def calcRedemptionFeePercentage(_fractionOfBLUSDToRedeem: uint256) -> uint256: nonpayable
    def getBondData(_bondID: uint256) -> (uint256, uint64, uint64, uint64, uint8): nonpayable
    def getLUSDToAcquire(_bondID: uint256) -> uint256: nonpayable
    def calcAccruedBLUSD(_bondID: uint256) -> uint256: nonpayable
    def calcBondBLUSDCap(_bondID: uint256) -> uint256: nonpayable
    def getLUSDInBAMMSPVault() -> uint256: nonpayable
    def calcTotalYearnCurveVaultShareValue() -> uint256: nonpayable
    def calcTotalLUSDValue() -> uint256: nonpayable
    def getPendingLUSD() -> uint256: nonpayable
    def getAcquiredLUSDInSP() -> uint256: nonpayable
    def getAcquiredLUSDInCurve() -> uint256: nonpayable
    def getTotalAcquiredLUSD() -> uint256: nonpayable
    def getPermanentLUSD() -> uint256: nonpayable
    def getOwnedLUSDInSP() -> uint256: nonpayable
    def getOwnedLUSDInCurve() -> uint256: nonpayable
    def calcSystemBackingRatio() -> uint256: nonpayable
    def calcUpdatedAccrualParameter() -> uint256: nonpayable
    def getBAMMLUSDDebt() -> uint256: nonpayable
