
interface IERC4626:
    def name() -> String[18]: view
    def symbol() -> String[18]: view
    def decimals() -> uint8: view

    def deposit(assets: uint256, receiver: address)  -> uint256: payable
    def withdraw(assets: uint256, receiver: address, owner: address) -> uint256: payable
    def mint(shares: uint256, receiver: address) -> uint256: payable
    def redeem(shares: uint256, receiver: address, owner: address) -> uint256: payable
    # getters
    def asset() -> address: view
    def totalAssets() -> uint256: view
    # @notice amount of shares that the Vault would exchange for the amount of assets provided
    def convertToShares(assets: uint256) -> uint256: view 
    # @notice amount of assets that the Vault would exchange for the amount of shares provided
    def convertToAssets(shares: uint256) -> uint256: view
    # @notice maximum amount of assets that can be deposited into vault for receiver
    def maxDeposit(receiver: address) -> uint256: view # @dev returns maxAssets
    # @notice simulate the effects of their deposit() at the current block, given current on-chain conditions.
    def previewDeposit(assets: uint256) -> uint256: view
    # @notice maximum amount of shares that can be deposited into vault for receiver
    def maxMint(receiver: address) -> uint256: view # @dev returns maxAssets
    # @notice simulate the effects of their mint() at the current block, given current on-chain conditions.
    def previewMint(shares: uint256) -> uint256: view
    # @notice maximum amount of assets that can be withdrawn into vault for receiver
    def maxWithdraw(receiver: address) -> uint256: view # @dev returns maxAssets
    # @notice simulate the effects of their withdraw() at the current block, given current on-chain conditions.
    def previewWithdraw(assets: uint256) -> uint256: view
    # @notice maximum amount of shares that can be withdrawn into vault for receiver
    def maxRedeem(receiver: address) -> uint256: view # @dev returns maxAssets
    # @notice simulate the effects of their redeem() at the current block, given current on-chain conditions.
    def previewRedeem(shares: uint256) -> uint256: view

# 4626 extension for referrals
interface IERC4626R:
    def depositWithReferral(assets: uint256, receiver: address, referrer: address)  -> uint256: payable
    def mintWithReferral(shares: uint256, receiver: address, referrer: address) -> uint256: payable
