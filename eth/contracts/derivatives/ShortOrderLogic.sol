pragma solidity 0.5.0;

import "./CompoundOrderLogic.sol";

contract ShortOrderLogic is CompoundOrderLogic {
  function executeOrder(uint256 _minPrice, uint256 _maxPrice) public onlyOwner isValidToken(tokenAddr) {
    super.executeOrder(_minPrice, _maxPrice);
    
    // Ensure token's price is between _minPrice and _maxPrice
    uint256 tokenPrice = compound.assetPrices(tokenAddr); // Get the shorting token's price in ETH
    require(tokenPrice > 0); // Ensure asset exists on Compound
    tokenPrice = __tokenToDAI(tokenAddr, tokenPrice); // Convert token price to be in DAI
    require(tokenPrice >= _minPrice && tokenPrice <= _maxPrice); // Ensure price is within range

    // Get funds in DAI from BetokenFund
    require(dai.transferFrom(owner(), address(this), collateralAmountInDAI)); // Transfer DAI from BetokenFund
    require(dai.approve(COMPOUND_ADDR, 0)); // Clear DAI allowance of Compound
    require(dai.approve(COMPOUND_ADDR, collateralAmountInDAI)); // Approve DAI transfer to Compound

    // Get loan from Compound in tokenAddr
    uint256 loanAmountInToken = __daiToToken(tokenAddr, loanAmountInDAI);
    require(compound.supply(DAI_ADDR, collateralAmountInDAI) == 0); // Transfer DAI into Compound as supply
    require(compound.borrow(tokenAddr, loanAmountInToken) == 0);// Take out loan
    require(compound.getAccountLiquidity(address(this)) > 0); // Ensure account liquidity is positive

    // Convert loaned tokens to DAI
    (uint256 actualDAIAmount,) = __sellTokenForDAI(loanAmountInToken);
    loanAmountInDAI = actualDAIAmount; // Change loan amount to actual DAI received

    // Repay leftover tokens to avoid complications
    if (token.balanceOf(address(this)) > 0) {
      uint256 repayAmount = token.balanceOf(address(this));
      require(token.approve(COMPOUND_ADDR, 0));
      require(token.approve(COMPOUND_ADDR, repayAmount));
      require(compound.repayBorrow(tokenAddr, repayAmount) == 0);
    }
  }

  function sellOrder(uint256 _minPrice, uint256 _maxPrice) 
    public 
    onlyOwner 
    isValidToken(tokenAddr) 
    isInitialized 
    returns (uint256 _inputAmount, uint256 _outputAmount) 
  {
    require(isSold == false);
    isSold = true;

    // Ensure price is within range provided by user
    uint256 tokenPrice = compound.assetPrices(tokenAddr); // Get the shorting token's price in ETH
    tokenPrice = __tokenToDAI(tokenAddr, tokenPrice); // Convert token price to be in DAI
    require(tokenPrice >= _minPrice && tokenPrice <= _maxPrice); // Ensure price is within range

    // Siphon remaining collateral by repaying x DAI and getting back 1.5x DAI collateral
    // Repeat to ensure debt is exhausted
    for (uint256 i = 0; i < MAX_REPAY_STEPS; i = i.add(1)) {
      uint256 currentDebt = __tokenToDAI(tokenAddr, compound.getBorrowBalance(address(this), tokenAddr));
      if (currentDebt <= NEGLIGIBLE_DEBT) {
        // Current debt negligible, exit
        break;
      }

      // Determine amount to be repayed this step
      uint256 currentBalance = dai.balanceOf(address(this));
      uint256 repayAmount = 0; // amount to be repaid in DAI
      if (currentDebt <= currentBalance) {
        // Has enough money, repay all debt
        repayAmount = currentDebt;
      } else {
        // Doesn't have enough money, repay whatever we can repay
        repayAmount = currentBalance;
      }

      // Repay debt
      repayLoan(repayAmount);

      // Withdraw all available liquidity
      require(compound.withdraw(DAI_ADDR, uint256(-1)) == 0);
    }

    // Send DAI back to BetokenFund and return
    _inputAmount = collateralAmountInDAI;
    _outputAmount = dai.balanceOf(address(this));
    require(dai.transfer(owner(), dai.balanceOf(address(this))));
  }

  // Allows manager to repay loan to avoid liquidation
  function repayLoan(uint256 _repayAmountInDAI) public onlyOwner isValidToken(tokenAddr) isInitialized {
    // Convert DAI to shorting token
    (,uint256 actualTokenAmount) = __sellDAIForToken(_repayAmountInDAI);

    // Repay loan to Compound
    require(token.approve(COMPOUND_ADDR, 0));
    require(token.approve(COMPOUND_ADDR, actualTokenAmount));
    require(compound.repayBorrow(tokenAddr, actualTokenAmount) == 0);
  }

  function getCurrentProfitInDAI() public view returns (bool _isNegative, uint256 _amount) {
    uint256 borrowBalance = __tokenToDAI(tokenAddr, compound.getBorrowBalance(address(this), tokenAddr));
    if (loanAmountInDAI >= borrowBalance) {
      return (false, loanAmountInDAI.sub(borrowBalance));
    } else {
      return (true, borrowBalance.sub(loanAmountInDAI));
    }
  }

  function getCurrentCollateralRatioInDAI() public view returns (uint256 _amount) {
    uint256 supply = compound.getSupplyBalance(address(this), DAI_ADDR);
    uint256 borrow = __tokenToDAI(tokenAddr, compound.getBorrowBalance(address(this), tokenAddr));
    return supply.mul(PRECISION).div(borrow);
  }
}