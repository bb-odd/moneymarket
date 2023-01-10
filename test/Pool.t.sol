// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/Pool.sol";
import "forge-std/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PoolTest is Test {
    Pool public pool;
    address constant binance = 0xF977814e90dA44bFA03b6295A0616a897441aceC;
    address constant dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    ERC20 daiToken;

    function setUp() public {
        pool = new Pool(
            dai,
            "Pool Dai",
            "pDai",
            8,
            0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9,
            12e16,
            4e16,
            5e16
        );
        daiToken = ERC20(dai);
    }

    // helper function that adds 1 lender and 1 borrower to the pool
    function enterPool(uint256 _amount) public {
        getDai(binance, _amount);

        vm.startPrank(address(1));
        daiToken.approve(address(pool), type(uint256).max);
        pool.supply(1000 * 10 ** 18);
        vm.stopPrank();

        vm.startPrank(address(2));
        pool.addCollateral{value: 1 * 10 ** 18}();
        vm.stopPrank();
    }

    function getDai(address _holder, uint256 _amount) public {
        vm.startPrank(_holder);
        daiToken.transferFrom(_holder, address(this), _amount);
        daiToken.transferFrom(_holder, address(1), _amount);
        daiToken.transferFrom(_holder, address(2), _amount);
        vm.stopPrank();
    }

    function testCheckOwner() public {
        assertEq(pool.owner(), address(this));
    }

    // test lending 1000 dai to pool test redeeming pool tokens to get initial dai lended back
    function testTokenLendRedeem() public {
        getDai(binance, 1000 * 10 ** 18);
        daiToken.approve(address(pool), type(uint256).max);
        pool.supply(1000 * 10 ** 18);
        assertEq(pool.balanceOf(address(this)), 1000 * 10 ** 18);

        pool.redeem(pool.balanceOf(address(this)));
        assertEq(daiToken.balanceOf(address(this)), 1000 * 10 ** 18);
    }

    function testAddRemoveCollateral() public {
        pool.addCollateral{value: 1 * 10 ** 18}();
        assertEq(1 * 10 ** 18, pool.getUserCollat(address(this)));
        assertEq(1 * 10 ** 18, address(pool).balance);

        uint256 balanceBefore = address(this).balance;
        pool.removeCollateral(1 * 10 ** 18);
        assertEq(1 * 10 ** 18, address(this).balance - balanceBefore);
    }

    // test get liquidity function
    // should return excess >= 0 when user is not in violation of borrow allowance (collateral * ltv >= borrows)
    // should return shortfall >= 0 when user has exceeded borrow allowance (collateral * ltv <= borrows)
    function testGetLiquidity() public {
        enterPool(10000 * 1e18);
        vm.startPrank(address(2));
        pool.borrow(1000 * 10 ** 18);
        (uint256 excess, uint256 shortfall) = pool.getLiquidity(address(2));
        require(excess >= 0 && shortfall == 0, "wrong liquidity calculation");

        vm.warp(block.timestamp + 365 days);
        pool.accrueInterest();
        (excess, shortfall) = pool.getLiquidity(address(2));
        require(excess == 0 && shortfall >= 0, "wrong liquidity calculation");
        vm.stopPrank();
    }

    // tests borrow() reverts when user doesn't have enough collateral available to borrow
    function testRevertGetLiquidity() public {
        enterPool(10000 * 1e18);
        vm.startPrank(address(2));
        vm.expectRevert(bytes("not enough collateral available!"));
        pool.borrow(1200 * 1e18);
        vm.stopPrank();
    }

    // test removeCollateral() reverts if amount to borrow exceeds liquidity of account]
    function testRevertRemoveCollateral() public {
        enterPool(10000 * 1e18);
        vm.startPrank(address(2));
        pool.borrow(1000 * 1e18);
        vm.expectRevert(bytes("not enough collateral available!"));
        pool.removeCollateral(1 * 1e18);
        vm.stopPrank();
    }

    // test revert can't pay more than owed debt
    function testRevertRepay() public {
        enterPool(10000 * 1e18);
        vm.startPrank(address(2));
        pool.borrow(1000 * 1e18);
        vm.expectRevert(bytes("can't repay more than owed debt!"));
        pool.repay(2000 * 1e18);
        vm.stopPrank();
    }

    // test reserves,debt, and exchange rate are increasing
    function testInterestGain() public {
        enterPool(10000 * 1e18);
        vm.startPrank(address(2));
        pool.borrow(1000 * 1e18);
        uint256 reserves = pool.getReserves();
        uint256 debt = pool.getTotalDebt();
        uint256 exchangeRate = pool.getLendExchangeRate();
        uint256 debtExchangeRate = pool.getDebtExchangeRate();
        vm.warp(block.timestamp + 100 days);
        pool.accrueInterest();
        require(reserves < pool.getReserves(), "reserves haven't increased!");
        require(debt < pool.getTotalDebt(), "total debt hasn't increased!");
        require(
            exchangeRate < pool.getLendExchangeRate(),
            "exchange rate hasn't increased!"
        );
        require(
            debtExchangeRate > pool.getDebtExchangeRate(),
            "debt exchange rate hasn't decreased"
        );
    }

    // test fully repaying debt after interest
    function testRepayDebt() public {
        enterPool(10000 * 1e18);

        vm.startPrank(address(2));
        daiToken.approve(address(pool), type(uint256).max);
        pool.borrow(1000 * 1e18);
        assertEq(pool.getUserBorrow(address(2)), 1000 * 1e18);

        vm.warp(block.timestamp + 365 days);

        pool.repay(1000 * 1e18);
        assertEq(pool.getUserBorrow(address(2)), 0);
        vm.stopPrank();
    }

    // test yearly interest should be around 12%
    // have 1 more person borrow and both borrow max dai possible

    // test exchange rates after users lend and borrow

    // test exchange rates after users lend and borrow and interest is accrued

    // test interest accrued ( 1 lender 1 borrower) (multiple lenders / borrowers)

    // test redeeming tokens after interest accrued ( 1 lender 1 borrower) (multiple lenders / borrowers)

    // test repaying debt after interest accrued ( 1 lender 1 borrower) (multiple lenders / borrowers)

    // test withdrawing collateral after repaying debt ( 1 lender 1 borrower) (multiple lenders / borrowers)

    // repeat these tests with tokens with different decimals

    // Function to receive Ether. msg.data must be empty
    receive() external payable {}

    // Fallback function is called when msg.data is not empty
    fallback() external payable {}
}
