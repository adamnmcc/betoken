pragma solidity 0.5.0;

import "openzeppelin-solidity/contracts/ownership/Ownable.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";
import "./tokens/minime/TokenController.sol";
import "./Utils.sol";
import "./BetokenProxy.sol";
import "./interfaces/IMiniMeToken.sol";

contract BetokenLogic is Ownable, Utils(address(0), address(0), address(0)), ReentrancyGuard {
  enum CyclePhase { Intermission, Manage }
  enum VoteDirection { Empty, For, Against }
  enum Subchunk { Propose, Vote }

  struct Investment {
    address tokenAddress;
    uint256 cycleNumber;
    uint256 stake;
    uint256 tokenAmount;
    uint256 buyPrice; // token buy price in 18 decimals in DAI
    uint256 sellPrice; // token sell price in 18 decimals in DAI
    uint256 buyTime;
    bool isSold;
  }

  uint256 public constant COMMISSION_RATE = 20 * (10 ** 16); // The proportion of profits that gets distributed to Kairo holders every cycle.
  uint256 public constant ASSET_FEE_RATE = 1 * (10 ** 15); // The proportion of fund balance that gets distributed to Kairo holders every cycle.
  uint256 public constant NEXT_PHASE_REWARD = 1 * (10 ** 18); // Amount of Kairo rewarded to the user who calls nextPhase().
  uint256 public constant MAX_BUY_KRO_PROP = 1 * (10 ** 16); // max Kairo you can buy is 1% of total supply
  uint256 public constant FALLBACK_MAX_DONATION = 100 * (10 ** 18); // If payment cap for registration is below 100 DAI, use 100 DAI instead
  uint256 public constant MIN_KRO_PRICE = 25 * (10 ** 17); // 1 KRO >= 2.5 DAI
  uint256 public constant COLLATERAL_RATIO_MODIFIER = 75 * (10 ** 16); // Modifies Compound's collateral ratio, gets 2:1 ratio from current 1.5:1 ratio
  uint256 public constant MIN_RISK_TIME = 9 days; // Mininum risk taken to get full commissions is 9 days * kairoBalance
  uint256 public constant CHUNK_SIZE = 3 days;
  uint256 public constant PROPOSE_SUBCHUNK_SIZE = 1 days;
  uint256 public constant CYCLES_TILL_MATURITY = 3;
  uint256 public constant QUORUM = 10 * (10 ** 16); // 10% quorum
  uint256 public constant VOTE_SUCCESS_THRESHOLD = 75 * (10 ** 16); // Votes on upgrade candidates need >75% voting weight to pass
  address public controlTokenAddr;
  address public shareTokenAddr;
  address public proxyAddr;
  address public compoundFactoryAddr;
  address public betokenLogic;
  address payable public developerFeeAccount;
  address payable public previousVersion;
  uint256 public cycleNumber;
  uint256 public totalFundsInDAI;
  uint256 public startTimeOfCyclePhase;
  uint256 public developerFeeRate;
  uint256 public exitFeeRate;
  uint256 public totalCommissionLeft;
  uint256[2] public phaseLengths;
  mapping(address => uint256) public lastCommissionRedemption;
  mapping(address => mapping(uint256 => uint256)) public riskTakenInCycle;
  mapping(address => uint256) public baseRiskStakeFallback;
  mapping(address => Investment[]) public userInvestments;
  mapping(address => address[]) public userCompoundOrders;
  mapping(uint256 => uint256) public totalCommissionOfCycle;
  mapping(uint256 => uint256) public managePhaseEndBlock;
  mapping(address => bool) public isStablecoin;
  CyclePhase public cyclePhase;
  bool public hasFinalizedNextVersion; // Denotes if the address of the next smart contract version has been finalized
  bool public upgradeVotingActive; // Denotes if the vote for which contract to upgrade to is active
  address payable public nextVersion; // Address of the next version of BetokenFund.
  address[5] public proposers; // Manager who proposed the upgrade candidate in a chunk
  address payable[5] public candidates; // Candidates for a chunk
  uint256[5] public forVotes; // For votes for a chunk
  uint256[5] public againstVotes; // Against votes for a chunk
  uint256 public proposersVotingWeight; // Total voting weight of previous and current proposers
  mapping(uint256 => mapping(address => VoteDirection[5])) public managerVotes; // Records each manager's vote
  mapping(uint256 => uint256) public upgradeSignalStrength; // Denotes the amount of Kairo that's signalling in support of beginning the upgrade process during a cycle
  mapping(uint256 => mapping(address => bool)) public upgradeSignal; // Maps manager address to whether they support initiating an upgrade
  IMiniMeToken internal cToken;
  IMiniMeToken internal sToken;
  BetokenProxy internal proxy;
  event ChangedPhase(uint256 indexed _cycleNumber, uint256 indexed _newPhase, uint256 _timestamp);
  event Deposit(uint256 indexed _cycleNumber, address indexed _sender, address _tokenAddress, uint256 _tokenAmount, uint256 _daiAmount, uint256 _timestamp);
  event Withdraw(uint256 indexed _cycleNumber, address indexed _sender, address _tokenAddress, uint256 _tokenAmount, uint256 daiAmount, uint256 _timestamp);
  event CreatedInvestment(uint256 indexed _cycleNumber, address indexed _sender, uint256 _id, address _tokenAddress, uint256 _stakeInWeis, uint256 _buyPrice, uint256 _costDAIAmount);
  event SoldInvestment(uint256 indexed _cycleNumber, address indexed _sender, uint256 _investmentId, uint256 _receivedKairo, uint256 _sellPrice, uint256 _earnedDAIAmount);
  event CreatedCompoundOrder(uint256 indexed _cycleNumber, address indexed _sender, address _order, bool _orderType, address _tokenAddress, uint256 _stakeInWeis, uint256 _costDAIAmount);
  event SoldCompoundOrder(uint256 indexed _cycleNumber, address indexed _sender, address _order,  bool _orderType, address _tokenAddress, uint256 _receivedKairo, uint256 _earnedDAIAmount);
  event RepaidCompoundOrder(uint256 indexed _cycleNumber, address indexed _sender, address _order, uint256 _repaidDAIAmount);
  event ROI(uint256 indexed _cycleNumber, uint256 _beforeTotalFunds, uint256 _afterTotalFunds);
  event CommissionPaid(uint256 indexed _cycleNumber, address indexed _sender, uint256 _commission);
  event TotalCommissionPaid(uint256 indexed _cycleNumber, uint256 _totalCommissionInDAI);
  event Register(address indexed _manager, uint256 indexed _block, uint256 _donationInDAI);
  event SignaledUpgrade(uint256 indexed _cycleNumber, address indexed _sender, bool indexed _inSupport);
  event DeveloperInitiatedUpgrade(uint256 indexed _cycleNumber, address _candidate);
  event InitiatedUpgrade(uint256 indexed _cycleNumber);
  event ProposedCandidate(uint256 indexed _cycleNumber, uint256 indexed _voteID, address indexed _sender, address _candidate);
  event Voted(uint256 indexed _cycleNumber, uint256 indexed _voteID, address indexed _sender, bool _inSupport, uint256 _weight);
  event FinalizedNextVersion(uint256 indexed _cycleNumber, address _nextVersion);


  /**
   * Upgrading functions
   */

  /**
   * @notice Allows the developer to propose a candidate smart contract for the fund to upgrade to.
   *          The developer may change the candidate during the Intermission phase.
   * @param _candidate the address of the candidate smart contract
   * @return True if successfully changed candidate, false otherwise.
   */
  function developerInitiateUpgrade(address payable _candidate) public returns (bool _success) {
    if (_candidate == address(0) || _candidate == address(this) || !__isMature()) {
      return false;
    }
    nextVersion = _candidate;
    upgradeVotingActive = true;
    emit DeveloperInitiatedUpgrade(cycleNumber, _candidate);
    return true;
  }

  /**
   * @notice Allows a manager to signal their support of initiating an upgrade. They can change their signal before the end of the Intermission phase.
   *          Managers who oppose initiating an upgrade don't need to call this function, unless they origianlly signalled in support.
   *          Signals are reset every cycle.
   * @param _inSupport True if the manager supports initiating upgrade, false if the manager opposes it.
   * @return True if successfully changed signal, false if no changes were made.
   */
  function signalUpgrade(bool _inSupport) public returns (bool _success) {
    if (!__isMature()) {
      return false;
    }

    if (upgradeSignal[cycleNumber][msg.sender] == false) {
      if (_inSupport == true) {
        upgradeSignal[cycleNumber][msg.sender] = true;
        upgradeSignalStrength[cycleNumber] = upgradeSignalStrength[cycleNumber].add(getVotingWeight(msg.sender));
      } else {
        return false;
      }
    } else {
      if (_inSupport == false) {
        upgradeSignal[cycleNumber][msg.sender] = false;
        upgradeSignalStrength[cycleNumber] = upgradeSignalStrength[cycleNumber].sub(getVotingWeight(msg.sender));
      } else {
        return false;
      }
    }
    emit SignaledUpgrade(cycleNumber, msg.sender, _inSupport);
    return true;
  }

  /**
   * @notice Allows manager to propose a candidate smart contract for the fund to upgrade to. Among the managers who have proposed a candidate,
   *          the manager with the most voting weight's candidate will be used in the vote. Ties are broken in favor of the larger address.
   *          The proposer may change the candidate they support during the Propose subchunk in their chunk.
   * @param _chunkNumber the chunk for which the sender is proposing the candidate
   * @param _candidate the address of the candidate smart contract
   * @return True if successfully proposed/changed candidate, false otherwise.
   */
  function proposeCandidate(uint256 _chunkNumber, address payable _candidate) public returns (bool _success) {
    // Input & state check
    if (!__isValidChunk(_chunkNumber) || currentChunk() != _chunkNumber || currentSubchunk() != Subchunk.Propose ||
      upgradeVotingActive == false || _candidate == address(0) || msg.sender == address(0) || !__isMature()) {
      return false;
    }

    // Ensure msg.sender has not been a proposer before
    // Ensure candidate hasn't been proposed in previous vote
    uint256 voteID = _chunkNumber.sub(1);
    uint256 i;
    for (i = 0; i < voteID; i = i.add(1)) {
      if (proposers[i] == msg.sender || candidates[i] == _candidate) {
        return false;
      }
    }

    // Ensure msg.sender has more voting weight than current proposer
    uint256 senderWeight = getVotingWeight(msg.sender);
    uint256 currProposerWeight = getVotingWeight(proposers[voteID]);
    if (senderWeight > currProposerWeight || (senderWeight == currProposerWeight && msg.sender > proposers[voteID]) || msg.sender == proposers[voteID]) {
      proposers[voteID] = msg.sender;
      candidates[voteID] = _candidate;
      proposersVotingWeight = proposersVotingWeight.add(senderWeight).sub(currProposerWeight); // remove proposer weight to prevent insufficient quorum
      emit ProposedCandidate(cycleNumber, _chunkNumber, msg.sender, _candidate);
      return true;
    }
    return false;
  }

  /**
   * @notice Allows a manager to vote for or against a candidate smart contract the fund will upgrade to. The manager may change their vote during
   *          the Vote subchunk. A manager who has been a proposer may not vote.
   * @param _inSupport True if the manager supports initiating upgrade, false if the manager opposes it.
   * @return True if successfully changed vote, false otherwise.
   */
  function voteOnCandidate(uint256 _chunkNumber, bool _inSupport) public returns (bool _success) {
    // Input & state check
    if (!__isValidChunk(_chunkNumber) || currentChunk() != _chunkNumber || currentSubchunk() != Subchunk.Vote || upgradeVotingActive == false || !__isMature()) {
      return false;
    }

    // Ensure msg.sender has not been a proposer before
    uint256 voteID = _chunkNumber.sub(1);
    uint256 i;
    for (i = 0; i < voteID; i = i.add(1)) {
      if (proposers[i] == msg.sender) {
        return false;
      }
    }

    // Register vote
    VoteDirection currVote = managerVotes[cycleNumber][msg.sender][voteID];
    uint256 votingWeight = getVotingWeight(msg.sender);
    if ((currVote == VoteDirection.Empty || currVote == VoteDirection.Against) && _inSupport) {
      managerVotes[cycleNumber][msg.sender][voteID] = VoteDirection.For;
      forVotes[voteID] = forVotes[voteID].add(votingWeight);
      if (currVote == VoteDirection.Against) {
        againstVotes[voteID] = againstVotes[voteID].sub(votingWeight);
      }
    } else if ((currVote == VoteDirection.Empty || currVote == VoteDirection.For) && !_inSupport) {
      managerVotes[cycleNumber][msg.sender][voteID] = VoteDirection.Against;
      againstVotes[voteID] = againstVotes[voteID].add(votingWeight);
      if (currVote == VoteDirection.For) {
        forVotes[voteID] = forVotes[voteID].sub(votingWeight);
      }
    }
    emit Voted(cycleNumber, _chunkNumber, msg.sender, _inSupport, votingWeight);
    return true;
  }

  /**
   * @notice Performs the necessary state changes after a successful vote
   * @param _chunkNumber the chunk number of the successful vote
   * @return True if successful, false otherwise
   */
  function finalizeSuccessfulVote(uint256 _chunkNumber) public returns (bool _success) {
    // Input & state check
    if (!__isValidChunk(_chunkNumber) || !__isMature()) {
      return false;
    }

    // Ensure the given vote was successful
    if (__voteSuccessful(_chunkNumber) == false) {
      return false;
    }

    // Ensure the chunk given has ended
    if (_chunkNumber >= currentChunk()) {
      return false;
    }

    // Ensure no previous vote was successful
    for (uint256 i = 1; i < _chunkNumber; i = i.add(1)) {
      if (__voteSuccessful(i)) {
        return false;
      }
    }

    // End voting process
    upgradeVotingActive = false;
    nextVersion = candidates[_chunkNumber.sub(1)];
    hasFinalizedNextVersion = true;
    return true;
  }

  /**
   * @notice Checks if the fund is mature enough for initiating an upgrade
   * @return True if mature enough, false otherwise
   */
  function __isMature() internal view returns (bool) {
    return cycleNumber > CYCLES_TILL_MATURITY;
  }

  /**
   * @notice Checks if a chunk number is valid
   * @param _chunkNumber the chunk number to be checked
   * @return True if valid, false otherwise
   */
  function __isValidChunk(uint256 _chunkNumber) internal pure returns (bool) {
    return _chunkNumber >= 1 && _chunkNumber <= 5;
  }

  /**
   * @notice Checks if a vote was successful
   * @param _chunkNumber the chunk number of the vote
   * @return True if successful, false otherwise
   */
  function __voteSuccessful(uint256 _chunkNumber) internal view returns (bool _success) {
    if (!__isValidChunk(_chunkNumber)) {
      return false;
    }
    uint256 voteID = _chunkNumber.sub(1);
    return forVotes[voteID].mul(PRECISION).div(forVotes[voteID].add(againstVotes[voteID])) > VOTE_SUCCESS_THRESHOLD
      && forVotes[voteID].add(againstVotes[voteID]) > getTotalVotingWeight().mul(QUORUM).div(PRECISION);
  }

  /**
   * @notice The manage phase is divided into 9 3-day chunks. Determines which chunk the fund's in right now.
   * @return The index of the current chunk (starts from 0). Returns 0 if not in Manage phase.
   */
  function currentChunk() public view returns (uint) {
    if (cyclePhase != CyclePhase.Manage) {
      return 0;
    }
    return (now - startTimeOfCyclePhase) / CHUNK_SIZE;
  }

  /**
   * @notice There are two subchunks in each chunk: propose (1 day) and vote (2 days).
   *         Determines which subchunk the fund is in right now.
   * @return The Subchunk the fund is in right now
   */
  function currentSubchunk() public view returns (Subchunk _subchunk) {
    if (cyclePhase != CyclePhase.Manage) {
      return Subchunk.Vote;
    }
    uint256 timeIntoCurrChunk = (now - startTimeOfCyclePhase) % CHUNK_SIZE;
    return timeIntoCurrChunk < PROPOSE_SUBCHUNK_SIZE ? Subchunk.Propose : Subchunk.Vote;
  }

  /**
   * @notice Calculates an account's voting weight based on their Kairo balance
   *         3 cycles ago
   * @param _of the account to be queried
   * @return The account's voting weight
   */
  function getVotingWeight(address _of) public view returns (uint256 _weight) {
    if (!__isMature() || _of == address(0)) {
      return 0;
    }
    return cToken.balanceOfAt(_of, managePhaseEndBlock[cycleNumber.sub(CYCLES_TILL_MATURITY)]);
  }

  /**
   * @notice Calculates the total voting weight based on the total Kairo supply
   *         3 cycles ago. The weights of proposers are deducted.
   * @return The total voting weight right now
   */
  function getTotalVotingWeight() public view returns (uint256 _weight) {
    if (!__isMature()) {
      return 0;
    }
    return cToken.totalSupplyAt(managePhaseEndBlock[cycleNumber.sub(CYCLES_TILL_MATURITY)]).sub(proposersVotingWeight);
  }


  /**
   * Next phase transition handler
   * @notice Moves the fund to the next phase in the investment cycle.
   */
  function nextPhase()
    public
  {
    require(now >= startTimeOfCyclePhase.add(phaseLengths[uint(cyclePhase)]));

    if (cycleNumber == 0) {
      require(msg.sender == owner());
    }

    if (cyclePhase == CyclePhase.Intermission) {
      require(hasFinalizedNextVersion == false); // Shouldn't progress to next phase if upgrading

      // Check if there is enough signal supporting upgrade
      if (upgradeSignalStrength[cycleNumber] > getTotalVotingWeight().div(2)) {
        upgradeVotingActive = true;
        emit InitiatedUpgrade(cycleNumber);
      }
    } else if (cyclePhase == CyclePhase.Manage) {
      // Burn any Kairo left in BetokenFund's account
      require(cToken.destroyTokens(address(this), cToken.balanceOf(address(this))));

      // Pay out commissions and fees
      uint256 profit = 0;
      if (getBalance(dai, address(this)) > totalFundsInDAI.add(totalCommissionLeft)) {
        profit = getBalance(dai, address(this)).sub(totalFundsInDAI).sub(totalCommissionLeft);
      }
      uint256 commissionThisCycle = COMMISSION_RATE.mul(profit).add(ASSET_FEE_RATE.mul(getBalance(dai, address(this)))).div(PRECISION);
      totalCommissionOfCycle[cycleNumber] = totalCommissionOfCycle[cycleNumber].add(commissionThisCycle); // account for penalties
      totalCommissionLeft = totalCommissionLeft.add(commissionThisCycle);
      uint256 devFee = developerFeeRate.mul(getBalance(dai, address(this))).div(PRECISION);
      uint256 newTotalFunds = getBalance(dai, address(this)).sub(totalCommissionLeft).sub(devFee);

      // Update values
      emit ROI(cycleNumber, totalFundsInDAI, newTotalFunds);
      totalFundsInDAI = newTotalFunds;

      // Transfer fees
      dai.transfer(developerFeeAccount, devFee);

      // Emit event
      emit TotalCommissionPaid(cycleNumber, totalCommissionOfCycle[cycleNumber]);

      managePhaseEndBlock[cycleNumber] = block.number;

      // Clear/update upgrade related data
      if (nextVersion == address(this)) {
        // The developer proposed a candidate, but the managers decide to not upgrade at all
        // Reset upgrade process
        delete nextVersion;
        delete hasFinalizedNextVersion;
      }
      if (nextVersion == address(0)) {
        delete proposers;
        delete candidates;
        delete forVotes;
        delete againstVotes;
        delete upgradeVotingActive;
        delete proposersVotingWeight;
      } else {
        hasFinalizedNextVersion = true;
        emit FinalizedNextVersion(cycleNumber, nextVersion);
      }

      // Start new cycle
      cycleNumber = cycleNumber.add(1);
    }

    cyclePhase = CyclePhase(addmod(uint(cyclePhase), 1, 2));
    startTimeOfCyclePhase = now;

    // Reward caller
    cToken.generateTokens(msg.sender, NEXT_PHASE_REWARD);

    emit ChangedPhase(cycleNumber, uint(cyclePhase), now);
  }


  /**
   * Manager registration
   */

  /**
   * @notice Calculates the current price of Kairo. The price is equal to the amount of DAI each Kairo
   *         can control, and it's kept above MIN_KRO_PRICE.
   * @return Kairo's current price
   */
  function kairoPrice() public view returns (uint256 _kairoPrice) {
    if (cToken.totalSupply() == 0) {return 0;}
    uint256 controlPerKairo = totalFundsInDAI.mul(PRECISION).div(cToken.totalSupply());
    if (controlPerKairo < MIN_KRO_PRICE) {
      // keep price above minimum price
      return MIN_KRO_PRICE;
    }
    return controlPerKairo;
  }
  
  /**
   * @notice Calculates the max amount a new manager can pay for an account. Equivalent to 1% of Kairo total supply.
   *         If less than 100 DAI, returns 100 DAI.
   * @return the max DAI amount for purchasing a manager account
   */
  function maxRegistrationPaymentInDAI() public view returns (uint256 _maxDonationInDAI) {
    uint256 kroPrice = kairoPrice();
    _maxDonationInDAI = MAX_BUY_KRO_PROP.mul(cToken.totalSupply()).div(PRECISION).mul(kroPrice).div(PRECISION);
    if (_maxDonationInDAI < FALLBACK_MAX_DONATION) {
      _maxDonationInDAI = FALLBACK_MAX_DONATION;
    }
  }

  /**
   * @notice Registers `msg.sender` as a manager, using DAI as payment. The more one pays, the more Kairo one gets.
   *         There's a max Kairo amount that can be bought, and excess payment will be sent back to sender.
   * @param _donationInDAI the amount of DAI to be used for registration
   */
  function registerWithDAI(uint256 _donationInDAI) public {
    require(dai.transferFrom(msg.sender, address(this), _donationInDAI));

    // if DAI value is greater than maximum allowed, return excess DAI to msg.sender
    uint256 maxDonationInDAI = maxRegistrationPaymentInDAI();
    if (_donationInDAI > maxDonationInDAI) {
      require(dai.transfer(msg.sender, _donationInDAI.sub(maxDonationInDAI)));
      _donationInDAI = maxDonationInDAI;
    }

    __register(_donationInDAI);
  }

  /**
   * @notice Registers `msg.sender` as a manager, using ETH as payment. The more one pays, the more Kairo one gets.
   *         There's a max Kairo amount that can be bought, and excess payment will be sent back to sender.
   */
  function registerWithETH() public payable {
    uint256 receivedDAI;

    // trade ETH for DAI
    (,,receivedDAI,) = __kyberTrade(ETH_TOKEN_ADDRESS, msg.value, dai);
    
    // if DAI value is greater than maximum allowed, return excess DAI to msg.sender
    uint256 maxDonationInDAI = maxRegistrationPaymentInDAI();
    if (receivedDAI > maxDonationInDAI) {
      require(dai.transfer(msg.sender, receivedDAI.sub(maxDonationInDAI)));
      receivedDAI = maxDonationInDAI;
    }

    // register new manager
    __register(receivedDAI);
  }

  /**
   * @notice Registers `msg.sender` as a manager, using tokens as payment. The more one pays, the more Kairo one gets.
   *         There's a max Kairo amount that can be bought, and excess payment will be sent back to sender.
   * @param _token the token to be used for payment
   * @param _donationInTokens the amount of tokens to be used for registration, should use the token's native decimals
   */
  function registerWithToken(address _token, uint256 _donationInTokens) public {
    require(_token != address(0) && _token != address(ETH_TOKEN_ADDRESS) && _token != DAI_ADDR);
    ERC20Detailed token = ERC20Detailed(_token);
    require(token.totalSupply() > 0);

    require(token.transferFrom(msg.sender, address(this), _donationInTokens));

    uint256 receivedDAI;

    (,,receivedDAI,) = __kyberTrade(token, _donationInTokens, dai);

    // if DAI value is greater than maximum allowed, return excess DAI to msg.sender
    uint256 maxDonationInDAI = maxRegistrationPaymentInDAI();
    if (receivedDAI > maxDonationInDAI) {
      require(dai.transfer(msg.sender, receivedDAI.sub(maxDonationInDAI)));
      receivedDAI = maxDonationInDAI;
    }

    // register new manager
    __register(receivedDAI);
  }

  /**
   * @notice Registers `msg.sender` as a manager.
   * @param _donationInDAI the amount of DAI to be used for registration
   */
  function __register(uint256 _donationInDAI) internal {
    require(cToken.balanceOf(msg.sender) == 0 && userInvestments[msg.sender].length == 0 && userCompoundOrders[msg.sender].length == 0); // each address can only join once

    // mint KRO for msg.sender
    uint256 kroAmount = _donationInDAI.mul(PRECISION).div(kairoPrice());
    require(cToken.generateTokens(msg.sender, kroAmount));

    // Set risk fallback base stake
    baseRiskStakeFallback[msg.sender] = kroAmount;

    // transfer DAI to developerFeeAccount
    require(dai.transfer(developerFeeAccount, _donationInDAI));
    
    // emit events
    emit Register(msg.sender, block.number, _donationInDAI);
  }


  /**
   * @notice Returns the commission balance of `_manager`
   * @return the commission balance, denoted in DAI
   */
  function commissionBalanceOf(address _manager) public view returns (uint256 _commission, uint256 _penalty) {
    if (lastCommissionRedemption[_manager] >= cycleNumber) { return (0, 0); }
    uint256 cycle = lastCommissionRedemption[_manager] > 0 ? lastCommissionRedemption[_manager] : 1;
    for (; cycle < cycleNumber; cycle = cycle.add(1)) {
      // take risk into account
      uint256 baseKairoBalance = cToken.balanceOfAt(_manager, managePhaseEndBlock[cycle.sub(1)]);
      uint256 baseStake = baseKairoBalance == 0 ? baseRiskStakeFallback[_manager] : baseKairoBalance;
      if (baseKairoBalance == 0 && baseRiskStakeFallback[_manager] == 0) { continue; }
      uint256 riskTakenProportion = riskTakenInCycle[_manager][cycle].mul(PRECISION).div(baseStake.mul(MIN_RISK_TIME)); // risk / threshold
      riskTakenProportion = riskTakenProportion > PRECISION ? PRECISION : riskTakenProportion; // max proportion is 1

      uint256 fullCommission = totalCommissionOfCycle[cycle].mul(cToken.balanceOfAt(_manager, managePhaseEndBlock[cycle]))
        .div(cToken.totalSupplyAt(managePhaseEndBlock[cycle]));
      uint256 commissionAfterPenalty = fullCommission.mul(riskTakenProportion).div(PRECISION);
      _commission = _commission.add(commissionAfterPenalty);
      _penalty = _penalty.add(fullCommission.sub(commissionAfterPenalty));
    }
  }
}