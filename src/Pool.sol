// SPDX-License-Identifier: MIT
pragma solidity ^0.8.8;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/AggregatorV3Interface.sol";

contract Pool is ERC20Burnable, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    uint256 public totalDeposit;
    uint256 public totalBorrowed;
    uint256 public totalDebt;
    uint256 public totalReserve;
    uint256 public ltv; // 1 = 10%
    address public immutable underlying;
    address public underlyingPriceFeed;
    address constant ethPriceFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    mapping(address => uint256) public usersCollateral;
    // this will store how much a user has borrowed not in underlying tokens but similar to how lenders receive pool tokens
    // underlying debt can be calculated using exchange rate and totalBorrowed
    mapping(address => uint256) public usersBorrowed;

    constructor(
        address _underlying,
        string memory _name,
        string memory _symbol,
        uint256 _ltv,
        address _aggregatorV3
    ) ERC20(_name, _symbol) {
        underlying = _underlying;
        ltv = _ltv;
        underlyingPriceFeed = _aggregatorV3;
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

        uint256 tokensToMint = _amount.mulDiv(
            10 ** decimals(),
            getLendExchangeRate()
        );

        _mint(msg.sender, tokensToMint);
    }

    function redeem(uint256 _amount) external {
        accrueInterest();

        uint256 underlyingToReceive = _amount.mulDiv(
            getLendExchangeRate(),
            10 ** decimals()
        );
        totalDeposit -= underlyingToReceive;

        burn(_amount);
        IERC20(underlying).safeTransfer(msg.sender, underlyingToReceive);
    }

    function addCollateral() external payable nonReentrant {
        require(msg.value != 0, "can't send 0 eth");
        accrueInterest();

        usersCollateral[msg.sender] += msg.value;
    }

    // remember that we need to use debtExchangeRate when checking liquidity as the borrows need to be converted to underlying debt that includes accrued interest

    function removeCollateral(uint256 _amount) external nonReentrant {
        require(_amount != 0, "can't withdraw 0 eth");
        require(_amount <= usersCollateral[msg.sender]);
        accrueInterest();
        (uint256 excess, uint256 shortfall) = getLiquidity(msg.sender);

        uint ethPrice = getEthPrice();

        require(
            excess >= _amount.mulDiv(uint(ethPrice), 10 ** 18),
            "not enough collateral available!"
        );

        usersCollateral[msg.sender] -= _amount;
        (bool success, ) = (msg.sender).call{value: _amount}("");
        require(success, "eth transfer failed");
    }

    function borrow(uint256 _amount) external nonReentrant {
        require(_amount != 0, "can't borrow 0 tokens");
        (uint256 excess, uint256 shortfall) = getLiquidity(msg.sender);

        uint underlyingPrice = getUnderlyingPrice();

        require(
            excess >= _amount.mulDiv(uint(underlyingPrice), 10 ** decimals()),
            "not enough collateral available!"
        );

        uint256 borrowedTokens = _amount.mulDiv(
            getDebtExchangeRate(),
            10 ** decimals()
        );

        usersBorrowed[msg.sender] += borrowedTokens;
        totalBorrowed += borrowedTokens;
        totalDebt += _amount;

        IERC20 token = IERC20(underlying);
        token.safeTransfer(msg.sender, _amount);
    }

    function repay(uint256 _amount) external nonReentrant {
        require(_amount != 0, "can't repay 0 tokens!");
        uint256 borrowToRepay = _amount.mulDiv(
            getDebtExchangeRate(),
            10 ** decimals()
        );
        require(
            borrowToRepay <= usersBorrowed[msg.sender],
            "can't repay more than owed debt!"
        );

        IERC20 token = IERC20(underlying);
        token.safeTransferFrom(msg.sender, address(this), _amount);

        usersBorrowed[msg.sender] -= borrowToRepay;
        totalBorrowed -= borrowToRepay;
        totalDebt -= _amount;
    }

    // return excess and shortfall in usd terms
    // at least one of excess or shortfall will be 0
    function getLiquidity(
        address _account
    ) public view returns (uint256, uint256) {
        uint ethPrice = getEthPrice();
        uint underlyingPrice = getUnderlyingPrice();

        uint256 debtUsd = (
            usersBorrowed[_account].mulDiv(
                10 ** decimals(),
                getDebtExchangeRate()
            )
        ).mulDiv(underlyingPrice, 10 ** decimals());

        uint256 collateralUsd = (usersCollateral[_account].mulDiv(ltv, 10))
            .mulDiv(ethPrice, 10 ** 18);

        uint256 excess = 0;
        uint256 shortfall = 0;

        if (collateralUsd >= debtUsd) {
            excess = collateralUsd - debtUsd;
        } else {
            shortfall = debtUsd - collateralUsd;
        }
        return (excess, shortfall);
    }

    // exchangeRate = cash + totalBorrowed - reserve / totalSupply
    // we minus reserve as that is kept for the protocol governance
    function getLendExchangeRate() public view returns (uint256) {
        uint256 totalSupply_ = totalSupply();
        if (totalSupply_ == 0) {
            return 10 ** decimals();
        }

        return
            (getCash() + totalBorrowed - totalReserve).mulDiv(
                10 ** decimals(),
                totalSupply_
            );
    }

    // exchangeRate = totalBorrowed/ totalDebt (debt accrues interest while borrowed is the amount of "pool tokens" borrowed)
    function getDebtExchangeRate() public view returns (uint256) {
        uint256 _totalBorrowed = totalBorrowed;
        if (_totalBorrowed == 0) {
            return 10 ** decimals();
        }
        return _totalBorrowed.mulDiv(10 ** decimals(), totalDebt);
    }

    function getCash() public view returns (uint256) {
        IERC20 token = IERC20(underlying);
        return token.balanceOf(address(this));
    }

    function getUserCollat(address _account) public view returns (uint256) {
        return usersCollateral[_account];
    }

    function getUserBorrow(address _account) public view returns (uint256) {
        return usersBorrowed[_account];
    }

    function getUnderlyingPrice() internal view returns (uint) {
        AggregatorV3Interface UnderlyingPriceFeed = AggregatorV3Interface(
            underlyingPriceFeed
        );

        (, int underlyingPrice, , , ) = UnderlyingPriceFeed.latestRoundData();

        return uint(underlyingPrice);
    }

    function getEthPrice() internal view returns (uint) {
        AggregatorV3Interface EthPriceFeed = AggregatorV3Interface(
            ethPriceFeed
        );

        (, int ethPrice, , , ) = EthPriceFeed.latestRoundData();

        return uint(ethPrice);
    }
}
