// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Pool is ERC20Burnable, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public totalDeposit;
    uint256 public totalBorrowed;
    uint256 public totalDebt;
    uint256 public totalReserve;
    uint256 public ltv; // 1 = 10%
    address public immutable underlying;
    mapping(address => uint256) usersCollateral;
    // this will store how much a user has borrowed not in underlying tokens but similar to how lenders receive pool tokens
    // underlying debt can be calculated using exchange rate and totalBorrowed
    mapping(address => uint256) usersBorrowed;

    constructor(
        address _underlying,
        string memory _name,
        string memory _symbol,
        uint256 _ltv
    ) ERC20(_name, _symbol) {
        underlying = _underlying;
        ltv = _ltv;
    }

    // ADMIN FUNCTIONS
    function setLTV(uint256 _ltv) external onlyOwner {
        ltv = _ltv;
    }

    // USER FUNCTIONS

    // updates totalDebt with interest accrued since last block this function was called
    function accrueInterest() public {}

    function supply(uint256 _amount) external {
        accrueInterest();

        IERC20(underlying).safeTransferFrom(msg.sender, address(this), _amount);
        totalDeposit += _amount;
        uint256 tokensToMint = _amount / getLendExchangeRate();
        _mint(msg.sender, _amount);
    }

    function redeem(uint256 _amount) external {
        require(_amount <= balanceOf(msg.sender), "Not enough tokens");
        accrueInterest();

        uint256 underlyingToReceive = _amount * getLendExchangeRate();
        totalDeposit -= underlyingToReceive;

        burnFrom(msg.sender, _amount);
        IERC20(underlying).safeTransfer(msg.sender, _amount);
    }

    function addCollateral() external payable nonReentrant {
        require(msg.value != 0, "can't send 0 eth");

        accrueInterest();
        usersCollateral[msg.sender] += msg.value;
    }

    // remember that we need to use debtExchangeRate when checking liquidity as the borrows need to be converted to underlying debt that includes accrued interest

    function removeCollateral(uint256 _amount) external nonReentrant {
        require(_amount != 0, "can't withdraw 0 eth");
        (uint256 excess, uint256 shortfall) = getLiquidity(msg.sender);
        require(
            excess >= _amount * oracleprice,
            "not enough collateral available!"
        );
        accrueInterest();

        usersCollateral[msg.sender] -= _amount;
        (bool success, ) = msg.sender.call{value: _amount}("");
        require(success, "eth transfer failed");
    }

    function borrow(uint256 _amount) external nonReentrant {
        // check account liquidity, if they have borrows that exceed invariant of collat * ltv >= borrows + amount
        require(_amount != 0, "can't borrow 0 tokens");
        (uint256 excess, uint256 shortfall) = getLiquidity(msg.sender);
        require(excess >= _amount, "not enough collateral available!");

        usersBorrowed[msg.sender] += _amount * getDebtExchangeRate();
        totalBorrowed += _amount;

        IERC20 token = IERC20(underlying);
        token.safeTransfer(msg.sender, _amount);
    }

    function repay() external nonReentrant {}

    function getLiquidity(address _account) public returns (uint256, uint256) {
        uint256 debt = usersBorrowed[_account].mulDiv(
            10 ** decimals,
            getDebtExchangeRate()
        );

        uint256 collateral = (usersCollateral(_account) * ltv) / 10; // * oracle price
        uint256 excess = 0;
        uint256 shortfall = 0;

        if (collateral >= debt) {
            excess = collateral - debt;
        } else {
            shortfall = debt - collateral;
        }
        return (excess, shortfall);
    }

    // exchangeRate = cash + totalBorrowed - reserve / totalSupply
    // we minus reserve as that is kept for the protocol governance
    function getLendExchangeRate() public view returns (uint256) {
        uint256 _totalSupply = totalSupply;
        if (_totalSupply == 0) {
            return 10 ** decimals;
        }

        return
            (getCash() + totalBorrowed - totalReserve).mulDiv(
                10 ** decimals,
                _totalSupply
            );
    }

    // exchangeRate = totalDebt/ totalBorrowed (debt accrues interest while borrowed is the amount of "pool tokens" borrowed)
    function getDebtExchangeRate() public view returns (uint256) {
        uint256 _totalBorrowed = totalBorrowed;
        if (_totalBorrowed == 0) {
            return 10 ** decimals;
        }
        return totalDebt.mulDiv(10 ** decimals, _totalBorrowed);
    }

    function getCash() public view returns (uint256) {
        IERC20 token = IERC20(underlying);
        return token.balanceOf(address(this));
    }
}
