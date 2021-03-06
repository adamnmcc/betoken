pragma solidity 0.5.0;

import "./BetokenFund.sol";

contract BetokenProxy {
  address public betokenFundAddress;
  BetokenFund internal betokenFund;

  constructor(address payable _fundAddr) public {
    betokenFundAddress = _fundAddr;
    betokenFund = BetokenFund(_fundAddr);
  }

  function updateBetokenFundAddress() public {
    require(msg.sender == betokenFundAddress, "Sender not BetokenFund");
    address payable nextVersion = betokenFund.nextVersion();
    require(nextVersion != address(0), "Next version can't be empty");
    betokenFundAddress = nextVersion;
    betokenFund = BetokenFund(nextVersion);
  }
}