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

contract PoolDelegateTest is Test {

    string constant POOL_NAME = "Test Pool";
    string constant POOL_SYMBOL = "TP";

    VyperDeployer vyperDeployer = new VyperDeployer();
    
    LineFactory lineFactory;
    ModuleFactory moduleFactory;
    SimpleOracle oracle;
    SecuredLine line;

    IBondToken iTokenA;
    IBondToken iTokenB;

    IDebtDAOPool pool;
    Fees fees;

    address delegate;
    address arbiter;
    address borrower;
    address swapTarget;

    uint256 ttl = 180 days;

    function setUp() public {
        delegate = makeAddr("delegate");
        arbiter = makeAddr("arbiter");
        borrower = makeAddr("borroer");
        swapTarget = makeAddr("swapTargey");

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
    function test_can_add_credit() public {

        address depositerA = makeAddr("depositerA");
        address depositerB = makeAddr("depositerB");
        iTokenA.mint(depositerA, 100 ether);
        iTokenA.mint(depositerB, 100 ether);

        vm.startPrank(depositerA);
        iTokenA.approve(address(pool), 100 ether);
        pool.deposit(100 ether, depositerA); // depositer will receive the pool tokens
        vm.stopPrank();

        vm.startPrank(depositerB);
        iTokenA.approve(address(pool), 100 ether);
        pool.deposit(100 ether, depositerB); // depositer will receive the pool tokens
        vm.stopPrank();

         vm.startPrank(delegate);
         bytes32 id = pool.add_credit(address(line), 1000, 1000, 200 ether);
    }
    
    // =================== INTERNAL HELPERS

    function _deployLine() internal {
        moduleFactory = new ModuleFactory();
        lineFactory = new LineFactory(
            address(moduleFactory),
            arbiter,
            address(oracle),
            payable(swapTarget) // swap target
        );
        address lineAddr = lineFactory.deploySecuredLine(borrower, ttl);
        line = SecuredLine(payable(lineAddr));
    }

}