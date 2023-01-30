// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "forge-std/Test.sol";

import {VyperDeployer} from "./utils/VyperDeployer.sol";
import {IBondToken} from "./interfaces/IBondToken.sol";
import {IDebtDAOPool, Fees} from "./interfaces/IDebtDAOPool.sol";

contract PoolDelegateTest is Test {

    string constant POOL_NAME = "Test Pool";
    string constant POOL_SYMBOL = "TP";

    VyperDeployer vyperDeployer = new VyperDeployer();
    
    IBondToken iToken;
    IDebtDAOPool pool;
    Fees fees;

    address delegate;

    function setUp() public {
        delegate = makeAddr("delegate");

        iToken = IBondToken(
            vyperDeployer.deployContract(
                "tests/mocks/MockERC20",
                abi.encode(
                    "Vyper Token", // name
                    "VTK", // symbol
                    18 //decimals
                )
            )
        );

        fees = Fees(
            100,
            20,
            20,
            10,
            50,
            20
        );

        // deploy the pool as teh delegate
        vm.startPrank(delegate);
        pool = IDebtDAOPool(
            vyperDeployer.deployContract(
                "contracts/DebtDAOPool",
                abi.encode(
                    delegate,           // delegate
                    address(iToken),    // asset
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

        vm.startPrank(user);
        pool.deposit(100 ether, address(0));
        vm.stopPrank();
    }

    function test_can_deposit_into_pool() public {
        address depositer = makeAddr("depositer");
        address recipient = makeAddr("recipient");

        iToken._mint_for_testing(depositer, 120 ether);
        assertEq(iToken.balanceOf(depositer), 120 ether, "incorrect token balance");
        vm.startPrank(depositer);
        pool.deposit(100 ether, recipient);
        vm.stopPrank();

        assertEq(iToken.balanceOf(depositer), 20 ether, "user balance does not match after depositing into pool");
    }


    // =================== CREDIT

    function test_cannot_add_credit_as_non_delegate() external {
        vm.expectRevert("not owner");
        address line = makeAddr("line");

        vm.startPrank(makeAddr("nondelegate"));
        pool.add_credit(line, 200, 200, 1 ether);
        vm.stopPrank();
    }
    function test_can_add_credit() public {

    }
    

    // function test_pool_fee_structure(uint16 _performance, uint16 _deposit, uint16 _withdraw, uint16 _flash, uint16 _collector, uint16 _referral ) public {
    //     // _performance = uint16(bound(_performance, 0, 20));
    //     // _deposit = uint16(bound(_deposit, 0, 20));
    //     // _withdraw = uint16(bound(_withdraw, 0, 20));
    //     // _flash = uint16(bound(_flash, 0, 20));
    //     // _collector = uint16(bound(_collector, 0, 20));
    //     // _referral = uint16(bound(_referral, 0, 20));

    //     fees = Fees(
    //         _performance,
    //         _deposit,
    //         _withdraw,
    //         _flash,
    //         _collector,
    //         _referral
    //     );

    //     pool = IDebtDAOPool(
    //         vyperDeployer.deployContract(
    //             "contracts/DebtDAOPool",
    //             abi.encode(
    //                 delegate,           // delegate
    //                 address(iToken),    // asset
    //                 "Test Pool",        // name
    //                 "TP",               // symbol
    //                 fees                // fees
    //             )
    //         )
    //     );

    // }
}