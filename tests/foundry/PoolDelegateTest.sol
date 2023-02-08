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

    IBondToken iTokenA;
    IBondToken iTokenB;

    IDebtDAOPool pool;
    Fees fees;

    address delegate;
    address arbiter;
    address borrower;
    address swapTarget;

    address userA;
    address userB;

    uint256 ttl = 180 days;

    function setUp() public {
        delegate = makeAddr("delegate");
        arbiter = makeAddr("arbiter");
        borrower = makeAddr("borrower");
        swapTarget = makeAddr("swapTarget");
        userA = makeAddr("userA");
        userB = makeAddr("userB");

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
            100,
            20,
            20,
            10,
            50,
            20
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
        assertEq(iTokenA.balanceOf(depositer), 120 ether, "incorrect token balance");

        vm.startPrank(depositer);
        iTokenA.approve(address(pool), 100 ether);
        pool.deposit(100 ether, recipient);
        vm.stopPrank();

        assertEq(iTokenA.balanceOf(depositer), 20 ether, "user balance does not match after depositing into pool");
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

        _usersDepositIntoPool();

        bytes32 id = _addCredit();

        vm.warp(block.timestamp + 30 days);
        vm.startPrank(borrower);
        line.increaseCredit(id, 1 ether);
        vm.stopPrank();

        vm.startPrank(delegate);
        pool.increase_credit(address(line), id, 1 ether);
        vm.stopPrank();

    }

    function test_non_pool_line() public {
        address lender = makeAddr("lender");
        iTokenA.mint(lender, 200 ether);

        vm.startPrank(lender);
        iTokenA.approve(address(nonPoolLine), 100 ether);
        nonPoolLine.addCredit(1000, 1000, 100 ether, address(iTokenA), lender);
        vm.stopPrank();

        vm.startPrank(borrower);
        bytes32 id = nonPoolLine.addCredit(1000, 1000, 100 ether, address(iTokenA), lender);
        emit log_named_bytes32("nonPool ID", id);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);

        vm.startPrank(lender);
        nonPoolLine.increaseCredit(id, 100 ether);
        vm.stopPrank();
    }

    function test_can_set_rates() public {
        _usersDepositIntoPool();
        bytes32 id = _addCredit();

        vm.startPrank(delegate);
        pool.set_rates(address(line), id, 500,500);
        vm.stopPrank();
    }
    
    // =================== INTERNAL HELPERS

    function _usersDepositIntoPool() internal {
 
        iTokenA.mint(userA, 150 ether);
        iTokenA.mint(userB, 150 ether);

        vm.startPrank(userA);
        iTokenA.approve(address(pool), 150 ether);
        pool.deposit(150 ether, userA); // depositer will receive the pool tokens
        vm.stopPrank();

        vm.startPrank(userB);
        iTokenA.approve(address(pool), 150 ether);
        pool.deposit(150 ether, userB); // depositer will receive the pool tokens
        vm.stopPrank();
    }

    function _deployLine() internal {
        moduleFactory = new ModuleFactory();
        lineFactory = new LineFactory(
            address(moduleFactory),
            arbiter,
            address(oracle),
            payable(swapTarget) // swap target
        );
        address nonPoolLineAddr = lineFactory.deploySecuredLine(borrower, ttl);
        address lineAddr = lineFactory.deploySecuredLine(borrower, ttl);
        line = SecuredLine(payable(lineAddr));
        nonPoolLine = SecuredLine(payable(nonPoolLineAddr));
    }

    function _deployPool() internal {
        // deploy the pool as the delegate
        vm.startPrank(delegate);
        pool = IDebtDAOPool(
            vyperDeployer.deployContract(
                "contracts/DebtDAOPool",
                abi.encode(
                    delegate,           // delegate
                    address(iTokenA),    // asset
                    POOL_NAME,          // name
                    POOL_SYMBOL,        // symbol
                    fees                // fees
                )
            )
        );

        pool.set_min_deposit(0.1 ether);
        vm.stopPrank();
    }

    function _addCredit() internal returns (bytes32 id){
        vm.startPrank(delegate);
        vm.expectEmit(false, false, false, false);
        emit MutualConsentRegistered(bytes32(0), borrower);
        pool.add_credit(address(line), 1000, 1000, 200 ether);
        vm.stopPrank();

        vm.startPrank(borrower);
        id = line.addCredit(1000, 1000, 200 ether, address(iTokenA), address(pool));
        emit log_named_bytes32("pool ID", id);
        vm.stopPrank();
    }

}