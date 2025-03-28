// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/ICreditSystem.sol";
import "./interfaces/IValidatorFactory.sol";
import "./interfaces/IValidator.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

contract PurseContract {
    using SafeERC20 for IERC20;

    enum PurseState {
        Open,      // Initial state, accepting members
        Active,    // All members joined, contributions started
        Completed, // All rounds completed
        Terminated // Emergency stop
    }

    struct Purse {
        PurseState state;
        uint256 contributionAmount;    // Amount each member contributes per round
        uint256 totalContributions;    // Total contributions in current round
        uint256 roundInterval;         // Time between rounds
        uint256 lastContributionTime;  // Timestamp of last contribution round
        uint256 currentRound;          // Current round number (1-based)
        uint256 maxMembers;            // Maximum number of members
        uint256 requiredCredits;       // Credits required to join
        address tokenAddress;          // ERC20 token used for contributions
        uint256 maxDelayTime;         // Maximum allowed delay time before admin intervention
        address admin;                // Admin address (usually the creator)
    }

    // Member struct to track individual member details
    struct Member {
        bool hasJoined;
        uint256 position;              // Position in rotation (1-based)
        bool hasContributedCurrentRound;
        bool hasReceivedPayout;
        uint256 totalContributed;
        uint256 lastContributionTime;
        address validator;           // Validator who vouched for the member
    }

    Purse public purse;
    IERC20 public token;
    ICreditSystem public immutable creditSystem;
    IValidatorFactory public validatorFactory;
    
    // Add state variable to track penalties
    uint256 public defaulterPenalties;
    
    mapping(address => Member) public members;
    address[] public memberList;
    mapping(uint256 => address) public positionToMember;

    // Events
    event PurseCreated(address indexed creator, uint256 contributionAmount, uint256 maxMembers);
    event MemberJoined(address indexed member, uint256 position);
    event ContributionMade(address indexed member, uint256 amount, uint256 round);
    event PayoutDistributed(address indexed member, uint256 amount, uint256 round);
    event PurseStateChanged(PurseState newState);
    event RoundCompleted(uint256 round);
    event RoundResolutionStarted(uint256 round);
    event BatchProcessed(uint256 processedCount, uint256 currentIndex, uint256 totalMembers);
    event RoundResolutionCompleted(uint256 round);

    uint256 public constant MAX_DEFAULTERS_PER_BATCH = 5;
    uint256 public defaulterProcessingIndex;
    bool public isProcessingDefaulters;

    // Define custom errors at the contract level
    error AlreadyMember();
    error InvalidPosition();
    error PositionTaken();
    error PurseFull();
    error InsufficientCredits();
    error ValidatorRequired();
    error InvalidValidator();
    error ValidatorNotEligible();
    error UserNotValidated();
    error InvalidPurseState(PurseState required, PurseState current);
    error NotMember();
    error DelayTimeNotExceeded();
    error AlreadyProcessingDefaulters();
    error ResolutionNotStarted();
    error AlreadyContributed();
    error TooEarlyForContribution();
    error AlreadyReceivedPayout();
    error OnlyAdminCanCall();
    error InvalidInterval();
    error InvalidContributionAmount();

    modifier onlyMember() {
        if (!members[msg.sender].hasJoined) revert NotMember();
        _;
    }

    modifier inState(PurseState _state) {
        if (purse.state != _state) revert InvalidPurseState(_state, purse.state);
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != purse.admin) revert OnlyAdminCanCall();
        _;
    }

    constructor(
        address _admin,
        uint256 _contribution_amount,
        uint256 _max_members,
        uint256 _round_interval,
        address _token_address,
        uint8 _position,
        address _creditSystem,
        address _validatorFactory,
        uint256 _maxDelayTime
    ) {
        if (_position == 0 || _position > _max_members) revert InvalidPosition();
        if (_round_interval == 0) revert InvalidInterval();
        if (_contribution_amount == 0) revert InvalidContributionAmount();
        
        creditSystem = ICreditSystem(_creditSystem);
        token = IERC20(_token_address);
        validatorFactory = IValidatorFactory(_validatorFactory);

        purse = Purse({
            state: PurseState.Open,
            contributionAmount: _contribution_amount,
            totalContributions: 0,
            roundInterval: _round_interval,
            lastContributionTime: 0,
            currentRound: 1,
            maxMembers: _max_members,
            requiredCredits: _contribution_amount * (_max_members - 1),
            tokenAddress: _token_address,
            maxDelayTime: _maxDelayTime,
            admin: _admin
        });

        members[_admin] = Member({
            hasJoined: true,
            position: _position,
            hasContributedCurrentRound: false,
            hasReceivedPayout: false,
            totalContributed: 0,
            lastContributionTime: 0,
            validator: address(0)
        });

        memberList.push(_admin);
        positionToMember[_position] = _admin;

        emit PurseCreated(_admin, _contribution_amount, _max_members);
        emit MemberJoined(_admin, _position);
    }

    /**
     * @notice Allows a user to join the purse
     * @param _position The position in the rotation the user wants to take
     * @param _validator The validator address (can be address(0) if validators aren't required)
     */
    function joinPurse(uint256 _position, address _validator) external {
        // Check if user is already a member
        if (members[msg.sender].hasJoined) revert AlreadyMember();
        
        // Check if position is valid
        if (_position == 0 || _position > purse.maxMembers) revert InvalidPosition();
        
        // Check if position is already taken
        if (positionToMember[_position] != address(0)) revert PositionTaken();
        
        // Check if user has enough credits
        if (creditSystem.userCredits(msg.sender) < purse.requiredCredits) revert InsufficientCredits();
        
        // If validator is provided, verify it's valid
        if (_validator != address(0)) {
            // Check if user is validated by this validator
            if (!creditSystem.isUserValidatedBy(msg.sender, _validator)) revert UserNotValidated();
        }
        
        // Reduce user credits
        creditSystem.reduceCredits(msg.sender, purse.requiredCredits);
        
        // Add user to purse
        members[msg.sender] = Member({
            hasJoined: true,
            position: _position,
            hasContributedCurrentRound: false,
            hasReceivedPayout: false,
            totalContributed: 0,
            lastContributionTime: 0,
            validator: _validator // This can be address(0) if no validator was provided
        });
        
        positionToMember[_position] = msg.sender;
        memberList.push(msg.sender);
        
        emit MemberJoined(msg.sender, _position);
        
        // If all positions are filled, start the purse
        if (memberList.length == purse.maxMembers) {
            purse.state = PurseState.Active;
            purse.lastContributionTime = block.timestamp;
            emit PurseStateChanged(PurseState.Active);
        }
    }

    function contribute() external onlyMember inState(PurseState.Active) {
        Member storage member = members[msg.sender];
        if (member.hasContributedCurrentRound) revert AlreadyContributed();
        if (block.timestamp < purse.lastContributionTime) revert TooEarlyForContribution();

        token.safeTransferFrom(msg.sender, address(this), purse.contributionAmount);
        
        member.hasContributedCurrentRound = true;
        member.totalContributed += purse.contributionAmount;
        member.lastContributionTime = block.timestamp;
        purse.totalContributions += purse.contributionAmount;

        emit ContributionMade(msg.sender, purse.contributionAmount, purse.currentRound);

        // Check if all members have contributed
        if (purse.totalContributions == purse.contributionAmount * purse.maxMembers) {
            _distributePayout();
        }
    }

    function _distributePayout() internal {
        address recipient = positionToMember[purse.currentRound];
        Member storage member = members[recipient];
        require(!member.hasReceivedPayout, "Already received payout");

        // Calculate actual payout amount
        uint256 payoutAmount;
        if (!member.hasContributedCurrentRound) {
            // If recipient defaulted, they only get actual contributions
            payoutAmount = purse.totalContributions;
        } else {
            // If recipient contributed, they get all contributions plus penalties
            payoutAmount = purse.totalContributions + defaulterPenalties;
        }

        // Transfer payout and update state
        token.safeTransfer(recipient, payoutAmount);
        member.hasReceivedPayout = true;
        
        emit PayoutDistributed(recipient, payoutAmount, purse.currentRound);
        emit RoundCompleted(purse.currentRound);

        // Update round state
        if (purse.currentRound == purse.maxMembers) {
            purse.state = PurseState.Completed;
            emit PurseStateChanged(PurseState.Completed);
        } else {
            startNewRound();
        }
    }

    function startNewRound() internal {
        purse.currentRound++;
        purse.totalContributions = 0;
        defaulterPenalties = 0;  // Reset penalties for new round
        purse.lastContributionTime = block.timestamp;

        // Reset member states for new round
        for (uint256 i = 0; i < memberList.length; i++) {
            address memberAddr = memberList[i];
            members[memberAddr].hasContributedCurrentRound = false;
            members[memberAddr].hasReceivedPayout = false;
        }
    }

    function getCurrentRound() external view returns (
        uint256 round,
        address currentRecipient,
        uint256 totalContributions,
        uint256 nextContributionTime
    ) {
        return (
            purse.currentRound,
            positionToMember[purse.currentRound],
            purse.totalContributions,
            purse.lastContributionTime + purse.roundInterval
        );
    }

    function getMemberInfo(address _member) external view returns (
        bool hasJoined,
        uint256 position,
        bool hasContributedCurrentRound,
        bool hasReceivedPayout,
        uint256 totalContributed
    ) {
        Member memory member = members[_member];
        return (
            member.hasJoined,
            member.position,
            member.hasContributedCurrentRound,
            member.hasReceivedPayout,
            member.totalContributed
        );
    }

    function getAllMembers() external view returns (address[] memory) {
        return memberList;
    }

    // Modified to allow anyone to call and process defaulters automatically
    function startResolveRound() external inState(PurseState.Active) {
        if (block.timestamp < purse.lastContributionTime + purse.maxDelayTime) 
            revert DelayTimeNotExceeded();
        if (isProcessingDefaulters) revert AlreadyProcessingDefaulters();

        isProcessingDefaulters = true;
        defaulterProcessingIndex = 0;
        emit RoundResolutionStarted(purse.currentRound);
        
        // Process all defaulters immediately
        _processAllDefaulters();
    }

    // New function to process all defaulters at once
    function _processAllDefaulters() internal {
        address recipient = positionToMember[purse.currentRound];
        uint256 processedCount = 0;

        for (uint256 i = 0; i < memberList.length; i++) {
            address memberAddress = memberList[i];
            Member storage member = members[memberAddress];
            
            if (!member.hasContributedCurrentRound) {
                // Get member's validator
                address validator = member.validator;
                if (validator != address(0)) {
                    // Track penalty before reducing credits
                    defaulterPenalties += purse.contributionAmount;

                    // Reduce user's credits and validator stake
                    try creditSystem.reduceCreditsForDefault(
                        memberAddress,
                        recipient,
                        purse.contributionAmount,
                        validator
                    ) {
                        processedCount++;
                    } catch {
                        // If the call fails, continue processing other defaulters
                        continue;
                    }
                }
            }
        }

        emit BatchProcessed(processedCount, memberList.length, memberList.length);
        
        // Finalize round resolution
        finalizeRoundResolution();
    }

    // Keep this for backward compatibility but make it admin-only
    function processDefaultersBatch() external onlyAdmin {
        if (!isProcessingDefaulters) revert ResolutionNotStarted();
        
        uint256 batchEnd = Math.min(
            defaulterProcessingIndex + MAX_DEFAULTERS_PER_BATCH,
            memberList.length
        );

        address recipient = positionToMember[purse.currentRound];
        uint256 processedCount = 0;

        for (uint256 i = defaulterProcessingIndex; i < batchEnd; i++) {
            address memberAddress = memberList[i];
            Member storage member = members[memberAddress];
            
            if (!member.hasContributedCurrentRound) {
                // Get member's validator
                address validator = member.validator;
                if (validator != address(0)) {
                    // Track penalty before reducing credits
                    defaulterPenalties += purse.contributionAmount;

                    // Reduce user's credits and validator stake
                    try creditSystem.reduceCreditsForDefault(
                        memberAddress,
                        recipient,
                        purse.contributionAmount,
                        validator
                    ) {
                        processedCount++;
                    } catch {
                        // If the call fails, continue processing other defaulters
                        continue;
                    }
                }
            }
        }

        defaulterProcessingIndex = batchEnd;
        
        emit BatchProcessed(processedCount, defaulterProcessingIndex, memberList.length);

        if (defaulterProcessingIndex >= memberList.length) {
            finalizeRoundResolution();
        }
    }

    function finalizeRoundResolution() internal {
        if (!isProcessingDefaulters) revert ResolutionNotStarted();
        
        // Distribute payout if there are any contributions
        if (purse.totalContributions > 0) {
            _distributePayout();
        }
        
        // Reset processing state
        isProcessingDefaulters = false;
        defaulterProcessingIndex = 0;
        
        emit RoundResolutionCompleted(purse.currentRound);
    }

    function getResolutionProgress() external view returns (
        bool isProcessing,
        uint256 currentIndex,
        uint256 totalMembers,
        uint256 remainingToProcess
    ) {
        return (
            isProcessingDefaulters,
            defaulterProcessingIndex,
            memberList.length,
            memberList.length - defaulterProcessingIndex
        );
    }
}
