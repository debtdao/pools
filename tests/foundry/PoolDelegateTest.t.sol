// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "forge-std/Test.sol";

import {VyperDeployer} from "./utils/VyperDeployer.sol";
import {IBondToken} from "./interfaces/IBondToken.sol";
import {IDebtDAOPool, Fees} from "./interfaces/IDebtDAOPool.sol";
import {LineFactory} from "debtdao/modules/factories/LineFactory.sol";
import {ModuleFactory} from "debtdao/modules/factories/ModuleFactory.sol";
import {SimpleOracle} from "debtdao/mock/SimpleOracle.sol";
import {SecuredLine} from "debtdao/modules/credit/SecuredLine.sol";

import { LineLib } from "debtdao/utils/LineLib.sol";
import { ZeroEx } from "debtdao/mock/ZeroEx.sol";
import { ISpigot } from 'debtdao/interfaces/ISpigot.sol';
import {IEscrow} from "debtdao/interfaces/IEscrow.sol";

import {stdMath} from "forge-std/StdMath.sol";

interface Events {
    event MutualConsentRegistered(bytes32 proposalId, address taker);
}

contract PoolDelegateTest is Test, Events {
    string constant POOL_NAME = "Test Pool";
    string constant POOL_SYMBOL = "TP";

    VyperDeployer vyperDeployer = new VyperDeployer();

    LineFactory lineFactory;
    ModuleFactory moduleFactory;
    SimpleOracle oracle;
    SecuredLine line;
    SecuredLine nonPoolLine;

    ZeroEx dex; 

    IBondToken iTokenA;
    IBondToken iTokenB;

    IDebtDAOPool pool;
    Fees fees;

    address delegate;
    address arbiter;
    address borrower;

    address mockRevenueContract = address(0xbeef);

    address userA;
    address userB;

    uint256 ttl = 180 days;

    function setUp() public {
        delegate = makeAddr("delegate");
        arbiter = makeAddr("arbiter");
        borrower = makeAddr("borrower");
        userA = makeAddr("userA");
        userB = makeAddr("userB");

        dex = new ZeroEx();

        // deploy the tokens
        iTokenA = IBondToken(
            vyperDeployer.deployContract(
                "tests/mocks/MockERC20",
                abi.encode(
                    "Vyper Bond Token A", // name
                    "VTKA", // symbol
                    18 //decimals
                )
            )
        );
        iTokenB = IBondToken(
            vyperDeployer.deployContract(
                "tests/mocks/MockERC20",
                abi.encode(
                    "Vyper Bond Token B", // name
                    "VTKB", // symbol
                    18 //decimals
                )
            )
        );

        // deploy the oracle
        oracle = new SimpleOracle(address(iTokenA), address(iTokenB));

        fees = Fees(
            100, // performance
            20,  // deposit
            20,  // withdraw
            10,  // flash
            50,  // collector
            20   //  referral
        );
        _deployLine();
        _deployPool();
    }

    function test_can_deploy_pool() public {
        assertEq(pool.owner(), delegate, "owner not delegate");
        // assertEq(pool.name(), POOL_NAME, "Name not correct");
        // assertEq(pool.symbol(), POOL_SYMBOL, "Symbol Not correct");
    }

    // =================== DEPOSITS

    function test_cannot_deposit_less_than_min_assets() public {
        address recipient = makeAddr("recipient");
        vm.expectRevert();
        pool.deposit(0.0 ether, recipient);
    }

    function test_cannot_deposit_more_than_max_assets() public {
        address recipient = makeAddr("recipient");

        vm.startPrank(delegate);
        pool.set_max_assets(1000 ether);
        vm.stopPrank();

        vm.expectRevert();
        pool.deposit(1000.01 ether, recipient);
    }

    function test_cannot_deposit_with_empty_recipient() public {
        address user = makeAddr("depositer");
        iTokenA.mint(user, 120 ether);
        vm.startPrank(user);
        iTokenA.approve(address(pool), 100 ether);

        vm.expectRevert();
        pool.deposit(100 ether, address(0));
        vm.stopPrank();
    }

    function test_can_deposit_into_pool() public {
        address depositer = makeAddr("depositer");
        address recipient = makeAddr("recipient");

        iTokenA.mint(depositer, 120 ether);
        assertEq(
            iTokenA.balanceOf(depositer),
            120 ether,
            "incorrect token balance"
        );

        vm.startPrank(depositer);
        iTokenA.approve(address(pool), 100 ether);
        pool.deposit(100 ether, recipient);
        vm.stopPrank();

        assertEq(
            iTokenA.balanceOf(depositer),
            20 ether,
            "user balance does not match after depositing into pool"
        );
    }

    // =================== CREDIT

    function test_cannot_add_credit_as_non_delegate() external {
        address line = makeAddr("line");

        vm.startPrank(makeAddr("nondelegate"));
        vm.expectRevert("not owner");
        pool.add_credit(line, 200, 200, 1 ether);
        vm.stopPrank();
    }

    function test_can_add_credit_and_increase_credit() public {
        _usersDepositIntoPool(150 ether);

        bytes32 id = _addCredit(200 ether);

        vm.warp(block.timestamp + 30 days);
        vm.startPrank(borrower);
        line.increaseCredit(id, 1 ether);
        vm.stopPrank();

        vm.startPrank(delegate);
        pool.increase_credit(address(line), id, 1 ether);
        vm.stopPrank();
    }

    function test_cannot_add_credit_without_sufficient_funds() public {
        _usersDepositIntoPool(1 ether);
        bytes32 id = _addCredit(2 ether);
        vm.startPrank(delegate);
        vm.expectRevert(bytes("insufficient funds"));
        pool.increase_credit(address(line), id, 10 ether);
        vm.stopPrank();
    }

    function test_can_set_rates() public {
        _usersDepositIntoPool(150 ether);
        bytes32 id = _addCredit(200 ether);

        vm.startPrank(delegate);
        pool.set_rates(address(line), id, 500, 500);
        vm.stopPrank();
    }

    function test_cannot_set_rates_as_pleb() public {
        _usersDepositIntoPool(150 ether);
        bytes32 id = _addCredit(200 ether);

        vm.startPrank(makeAddr("pleb"));
        vm.expectRevert(bytes("not owner"));
        pool.set_rates(address(line), id, 500, 500);
        vm.stopPrank();
    }

    function test_can_collect_interest_as_anyone() public {
        _usersDepositIntoPool(150 ether);
        bytes32 id = _addCredit(200 ether);

        _addCollateral(100 ether);

        vm.startPrank(borrower);
        line.borrow(id, 50 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);

        vm.startPrank(borrower);
        iTokenA.approve(address(line), 20 ether);
        line.depositAndRepay(20 ether);
        vm.stopPrank();

        line.updateOutstandingDebt();
        (uint256 deposit, uint256 interest) = line.available(id);

        emit log_named_uint("deposit", deposit);
        emit log_named_uint("interest", interest);

        address caller = makeAddr("caller");
        uint256 callerBalance = iTokenA.balanceOf(caller);
        emit log_named_uint("caller balance", callerBalance);

        vm.startPrank(caller);
        uint256 poolEarned = pool.collect_interest(address(line), id);
        emit log_named_uint("poolEarned", poolEarned);
        vm.stopPrank();

        emit log_named_uint("caller balance after", iTokenA.balanceOf(caller));

        // caller fee should be {fees.collector}% of what the pool earned
        uint256 callerBalanceAfter = iTokenA.balanceOf(caller);

        uint256 callerPct = (callerBalanceAfter * 10000) / poolEarned;
        emit log_named_uint("pct", callerPct);
        assertEq(callerPct, fees.collector);
    }

    function test_cannot_abort_as_random_user() public {

        _usersDepositIntoPool(150 ether);
        bytes32 id = _addCredit(200 ether);

        address rando = makeAddr("rando");

        vm.startPrank(rando);
        vm.expectRevert(bytes("not owner"));
        pool.abort(address(line), id);
        vm.stopPrank();

    }

    function test_can_abort_as_delegate() public {
        _usersDepositIntoPool(150 ether);
        bytes32 id = _addCredit(200 ether);

        _addCollateral(100 ether);

        vm.startPrank(borrower);
        line.borrow(id, 50 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);

        line.updateOutstandingDebt();

        vm.startPrank(delegate);
        (uint256 principalWithdrawn, uint256 interestEarned) = pool.abort(address(line), id);
        vm.stopPrank();
        emit log_named_uint("interestEarned", interestEarned);
        assertEq(principalWithdrawn, 150 ether);

        // TODO: check interest amount

    }

    function test_cannot_reduce_credit_as_random_caller() public {
        _usersDepositIntoPool(150 ether);
        bytes32 id = _addCredit(200 ether);

        address rando = makeAddr("rando");

        vm.startPrank(rando);
        vm.expectRevert(bytes("not owner"));
        pool.reduce_credit(address(line), id, 100 ether);
        vm.stopPrank();
    }

    function test_can_reduce_credit_as_delegate() public {
        _usersDepositIntoPool(150 ether);
        bytes32 id = _addCredit(200 ether); 

        assertEq(iTokenA.balanceOf(address(line)), 200 ether);

        vm.startPrank(delegate);
        pool.reduce_credit(address(line), id, 100 ether);
        vm.stopPrank();

        assertEq(iTokenA.balanceOf(address(line)), 100 ether);

    }

    function test_cannot_use_and_repay_as_random_user() public {
        _usersDepositIntoPool(150 ether);
        bytes32 id = _addCredit(200 ether);

        address rando = makeAddr("rando");

        vm.startPrank(rando);
        vm.expectRevert(bytes("not owner"));
        pool.use_and_repay(address(line), 10 ether, 10 ether);
        vm.stopPrank();
    }

    function test_can_use_and_repay_as_delegate() public {
        _usersDepositIntoPool(150 ether);
        bytes32 id = _addCredit(200 ether);

        _addCollateral(100 ether);

        uint256 borrowAmount = 50 ether;

        vm.startPrank(borrower);
        line.borrow(id, borrowAmount);
        vm.stopPrank();

        // simulate revenue (push payment), owner split is 10%
        iTokenB.mint(address(line.spigot()), borrowAmount * 10); 

        ISpigot(line.spigot()).claimRevenue(mockRevenueContract, address(iTokenB), bytes(""));

        bytes memory tradeData = abi.encodeWithSignature(
            'trade(address,address,uint256,uint256)',
            address(iTokenB), // token in
            address(iTokenA), // token out
            20 ether, //amountIn
            10 ether // minAmountOut
        );

        vm.startPrank(arbiter);
        line.claimAndTrade(address(iTokenB), tradeData);
        vm.stopPrank();

        uint256 unused =  line.unused(address(iTokenA));
        emit log_named_uint("unused", unused);

      (, uint256 principal,uint256 interest,,,,,) = line.credits(id);

        emit log_named_uint("principal", principal);
        emit log_named_uint("interest", interest);

        vm.startPrank(delegate);
        pool.use_and_repay(address(line),  unused, 0);

        // TODO: check balances
    }

    function test_cannot_impair_when_line_not_insolvent() public {
        _usersDepositIntoPool(150 ether);
        bytes32 id = _addCredit(200 ether);

        _addCollateral(100 ether);

        uint256 borrowAmount = 50 ether;

        vm.startPrank(borrower);
        line.borrow(id, borrowAmount);
        vm.stopPrank();

        vm.expectRevert(bytes("not insolvent"));
        pool.impair(address(line), id);
    }

    function test_can_impair_when_line_insolvent() public {
        uint256 borrowAmount = 20 ether;

        _usersDepositIntoPool(150 ether);

        bytes32 id = _addCredit(borrowAmount);

        _addCollateral(borrowAmount/2);



        vm.startPrank(borrower);
        line.borrow(id, borrowAmount);
        vm.stopPrank();

        emit log_named_uint("user balance", iTokenA.balanceOf(address(borrower)));
        
        vm.startPrank(borrower);
        iTokenA.approve(address(line), type(uint256).max);
        line.depositAndRepay(borrowAmount/4);
        vm.stopPrank();

        vm.warp(block.timestamp + ttl + 1 days);

        assertEq(uint256(line.healthcheck()), uint256(LineLib.STATUS.LIQUIDATABLE));

        line.updateOutstandingDebt();

        (uint256 deposit, uint256 principal, uint256 interest, uint256 interestRepaid,,,,) = line.credits(id);

        emit log_named_uint("principal", principal);
        emit log_named_uint("interest", interest);
        emit log_named_uint("deposit", deposit);
        emit log_named_uint("interestRepaid", interestRepaid);

        uint256 collateralValue = IEscrow(address(line.escrow())).getCollateralValue();
        emit log_named_uint("collateralValue", collateralValue);

        vm.startPrank(arbiter);

        uint256 liquidationAmount = iTokenB.balanceOf(address(line.escrow()));
         emit log_named_uint("liquidationAmount", liquidationAmount);

        assertEq(liquidationAmount, line.liquidate(liquidationAmount, address(iTokenB)));

        collateralValue = IEscrow(address(line.escrow())).getCollateralValue();
        emit log_named_uint("collateralValue post liquidation", collateralValue);

        line.releaseSpigot(arbiter);
        ISpigot(line.spigot()).updateOwner(makeAddr("new owner"));


        line.declareInsolvent();
        assertEq(uint256(line.healthcheck()), uint256(LineLib.STATUS.INSOLVENT));

        vm.stopPrank();

        assertEq(uint256(line.status()), uint256(LineLib.STATUS.INSOLVENT));

        // TODO: should impair
        vm.startPrank(makeAddr("rando"));
        pool.impair(address(line), id);
        vm.stopPrank();
    }

    // =================== INTERNAL HELPERS

    function _usersDepositIntoPool(uint256 amt) internal {
        iTokenA.mint(userA, amt);
        iTokenA.mint(userB, amt);

        vm.startPrank(userA);
        iTokenA.approve(address(pool), amt);
        pool.deposit(amt, userA); // depositer will receive the pool tokens
        vm.stopPrank();

        vm.startPrank(userB);
        iTokenA.approve(address(pool), amt);
        pool.deposit(amt, userB); // depositer will receive the pool tokens
        vm.stopPrank();
    }

    function _deployLine() internal {
        moduleFactory = new ModuleFactory();
        lineFactory = new LineFactory(
            address(moduleFactory),
            arbiter,
            address(oracle),
            payable(address(dex)) // swap target
        );
        address nonPoolLineAddr = lineFactory.deploySecuredLine(borrower, ttl);
        address lineAddr = lineFactory.deploySecuredLine(borrower, ttl);
        line = SecuredLine(payable(lineAddr));
        nonPoolLine = SecuredLine(payable(nonPoolLineAddr));

        ISpigot.Setting memory setting = ISpigot.Setting({
            ownerSplit: 10,
            claimFunction: bytes4(0),
            transferOwnerFunction: bytes4("1234")
        });

        vm.prank(arbiter);
        line.addSpigot(mockRevenueContract, setting);

        iTokenA.mint(address(dex), 10_000 ether);
        iTokenB.mint(address(dex), 10_000 ether);
        iTokenA.approve(address(dex), type(uint256).max);
        iTokenB.approve(address(dex), type(uint256).max);
    }

    function _simulateRevenue(address token, uint256 amount) internal{
        IBondToken(token).mint(mockRevenueContract, amount);
        // iTokenB.mint(mockRevenueContract, amount);
    }

    function _deployPool() internal {
        // deploy the pool as the delegate
        vm.startPrank(delegate);
        pool = IDebtDAOPool(
            vyperDeployer.deployContract(
                "contracts/DebtDAOPool",
                abi.encode(
                    delegate, // delegate
                    address(iTokenA), // asset
                    POOL_NAME, // name
                    POOL_SYMBOL, // symbol
                    fees // fees
                )
            )
        );

        pool.set_min_deposit(0.1 ether);
        vm.stopPrank();
    }

    function _addCredit(uint256 amt) internal returns (bytes32 id) {
        vm.startPrank(delegate);
        vm.expectEmit(false, false, false, false);
        emit MutualConsentRegistered(bytes32(0), borrower);
        pool.add_credit(address(line), 1000, 1000, amt);
        vm.stopPrank();

        vm.startPrank(borrower);
        id = line.addCredit(1000, 1000, amt, address(iTokenA), address(pool));
        emit log_named_bytes32("pool ID", id);
        vm.stopPrank();
    }

    function _addCollateral(uint256 amt) internal {
        vm.startPrank(arbiter);
        IEscrow(address(line.escrow())).enableCollateral(address(iTokenB));
        vm.stopPrank();

        iTokenB.mint(borrower, amt);
        vm.startPrank(borrower);
        iTokenB.approve(address(line.escrow()), amt);
        IEscrow(address(line.escrow())).addCollateral(amt, address(iTokenB));
        vm.stopPrank();
    }
}
