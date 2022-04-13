// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

abstract contract Pausable {

    bool private _paused;

    constructor() {
        _paused = false;
    }

    function paused() public view virtual returns (bool) {
        return _paused;
    }

    modifier whenNotPaused() {
        require(!paused(), "Pausable: paused");
        _;
    }

    modifier whenPaused() {
        require(paused(), "Pausable: not paused");
        _;
    }

    function _pause() internal virtual whenNotPaused {
        _paused = true;
    }

    function _unpause() internal virtual whenPaused {
        _paused = false;
    }
}

interface PAIR {
    function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast);
}

contract OracleSC {
    address AVAX_USDC = 0x5cbF3Ac8007fBa2dD13a3128F800dd26d33B2C0A;

    function getAVAXPrice() public view returns (uint price) {
        (uint avax, uint usdc, ) = PAIR(AVAX_USDC).getReserves();
        price = usdc / avax;
    }
}

contract CoinPredictionSC is Pausable, OracleSC {
    constructor(address _admin, address _operator) {
        Admin = _admin;
        Operator = _operator;
    }

    struct Round {
        uint round;
        uint startTimestamp;
        uint lockTimestamp;
        uint closeTimestamp;
        uint lockPrice;
        uint closePrice;
        uint winnerId;      // House = 0, Bear = 1, Bull = 2
        uint totalAmount;   // Total bet
        uint bearAmount;    // Total bet by Bears
        uint bullAmount;    // Total bet by Bulls
        uint winnerBet;     // Total bet by winners
        uint distributed;   // Distributed to winners
    }

    struct BetInfo {
        uint position;      // Bear = 1, Bull = 2
        uint amount;
        bool claimed;
    }

    uint interval = 300;         // Interval between each round (in seconds)
    uint currentRound;
    uint treasuryAmount;        // Amount claimable by Admin
    uint treasuryFee = 250;     // 2.5%
    uint maxTreasuryFee = 1000; // 10%
    uint minBet = 50;
    uint maxBet = 1000;
    uint buffer = 60;           // Safety expiration time (in seconds)
    bool genesisStartOnce;
    bool genesisLockOnce;
    
    address Admin;
    address Operator;

    mapping(uint => Round) public rounds;
    mapping(address => uint[]) public userRounds;
    mapping(uint => mapping(address => BetInfo)) public ledger;

    function _safeTransferCRO(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}("");
        require(success, "TransferHelper: CRO_TRANSFER_FAILED");
    }

    function _startRound(uint _round) internal {
        require(genesisStartOnce, "Can only run after genesisStartRound is triggered.");
        require(rounds[_round-2].closeTimestamp != 0, "Can only start round after round n-2 has ended.");
        require(block.timestamp >= rounds[_round-2].closeTimestamp,"Can only start new round after round n-2 closeTimestamp.");

        rounds[_round].round = currentRound;
        rounds[_round].startTimestamp = block.timestamp;
        rounds[_round].lockTimestamp = block.timestamp + interval;
        rounds[_round].closeTimestamp = block.timestamp + (2*interval);
    }

    function _lockRound(uint _round) internal {
        require(rounds[_round].startTimestamp != 0, "Can only lock round after round has started.");
        require(block.timestamp >= rounds[_round].lockTimestamp, "Can only lock round after lockTimestamp.");
        require(block.timestamp <= rounds[_round].lockTimestamp + buffer, "Can only lock round within bufferSeconds.");

        rounds[_round].closeTimestamp = block.timestamp + interval;
        rounds[_round].lockPrice = getAVAXPrice();
    }

    function _endRound(uint _round) internal {
        require(rounds[_round].lockTimestamp != 0, "Can only end round after round has locked.");
        require(block.timestamp >= rounds[_round].closeTimestamp, "Can only end round after closeTimestamp.");
        require(block.timestamp <= rounds[_round].closeTimestamp + buffer, "Can only lock round within bufferSeconds.");

        rounds[_round].closePrice = getAVAXPrice();
    }

    function genesisStartRound() public onlyOperator whenNotPaused {
        require(!genesisStartOnce, "Can only run genesisStartRound once");
        
        currentRound += 1;
        
        rounds[currentRound].round = currentRound;
        rounds[currentRound].startTimestamp = block.timestamp;
        rounds[currentRound].lockTimestamp = block.timestamp + interval;
        rounds[currentRound].closeTimestamp = block.timestamp + (2*interval);

        genesisStartOnce = true;
    }

    function genesisLockRound() public onlyOperator whenNotPaused {
        require(genesisStartOnce, "Can only run after genesisStartRound is triggered.");
        require(!genesisLockOnce, "Can only run genesisLockRound once.");

        _lockRound(currentRound);
        currentRound += 1;
        
        rounds[currentRound].round = currentRound;
        rounds[currentRound].startTimestamp = block.timestamp;
        rounds[currentRound].lockTimestamp = block.timestamp + interval;
        rounds[currentRound].closeTimestamp = block.timestamp + (2*interval);

        genesisLockOnce = true;
    }

    // Has to be called every interval (2 times in a row for buffer safety)
    function executeRound() public onlyOperator whenNotPaused {
        require(genesisStartOnce && genesisLockOnce,"Can only run after genesisStartRound and genesisLockRound is triggered.");

        _lockRound(currentRound);
        _endRound(currentRound-1);
        _calculateRewards(currentRound-1);
        currentRound += 1;

        _startRound(currentRound);
    }

    function _calculateRewards(uint _round) internal {
        uint treasuryAmt;
        uint rewardAmount;

        // Bear wins
        if (rounds[_round].closePrice < rounds[_round].lockPrice) {
            rounds[_round].winnerId = 1;
            rounds[_round].winnerBet = rounds[_round].bearAmount;
            treasuryAmt = (rounds[_round].totalAmount * treasuryFee) / 10000;
            rewardAmount = rounds[_round].totalAmount - treasuryAmt;
        }
        // Bull wins
        else if (rounds[_round].closePrice > rounds[_round].lockPrice) {
            rounds[_round].winnerId = 2;
            rounds[_round].winnerBet = rounds[_round].bullAmount;
            treasuryAmt = (rounds[_round].totalAmount * treasuryFee) / 10000;
            rewardAmount = rounds[_round].totalAmount - treasuryAmt;
        }
        // House wins
        else {
            rounds[_round].winnerId = 0;
            rewardAmount = 0;
            treasuryAmt = rounds[_round].totalAmount;
        }

        rounds[_round].distributed = rewardAmount;
        treasuryAmount += treasuryAmt;
    }

    function betBear() public payable whenNotPaused {
        require(msg.value >= minBet && msg.value <= maxBet, "Bet amount not valid.");
        require(ledger[currentRound][msg.sender].amount == 0, "You have 1 bet per round.");

        uint amount = msg.value;
        rounds[currentRound].totalAmount += amount;
        rounds[currentRound].bearAmount += amount;

        userRounds[msg.sender].push(currentRound);

        ledger[currentRound][msg.sender].position = 1;
        ledger[currentRound][msg.sender].amount = amount;
    }

    function betBull() public payable whenNotPaused {
        require(msg.value >= minBet && msg.value <= maxBet, "Bet amount not valid.");
        require(ledger[currentRound][msg.sender].amount == 0, "You have 1 bet per round.");
        
        uint amount = msg.value;
        rounds[currentRound].totalAmount += amount;
        rounds[currentRound].bullAmount += amount;

        userRounds[msg.sender].push(currentRound);

        ledger[currentRound][msg.sender].position = 2;
        ledger[currentRound][msg.sender].amount = amount;
    }

    function claimable(uint _round, address _user) public view returns (bool) {
        if (rounds[_round].lockPrice == rounds[_round].closePrice) {
            return false;
        }
        return
            rounds[_round].closePrice != 0 &&
            ledger[_round][_user].amount != 0 &&
            ledger[_round][_user].claimed == false &&
            (
                (rounds[_round].closePrice > rounds[_round].lockPrice && ledger[_round][_user].position == 2) ||
                (rounds[_round].closePrice < rounds[_round].lockPrice && ledger[_round][_user].position == 1)
            );
    }

    function refundable(uint _round, address _user) public view returns (bool) {
        return
            rounds[_round].closePrice == 0 &&
            ledger[_round][_user].claimed == false &&
            block.timestamp > rounds[_round].closeTimestamp + buffer &&
            ledger[_round][_user].amount != 0;
    }

    function claim(uint[] memory _rounds) public { //EDIT WITH REFUNDS ON BUFFER EXPIRATION
        uint reward;

        for (uint i = 0; i < _rounds.length; i++) {
            uint epoch = _rounds[i];
            require(block.timestamp > rounds[epoch].closeTimestamp, "Round has not ended.");

            uint addedReward;

            if (rounds[_rounds[i]].closePrice != 0) {
                require(claimable(_rounds[i], msg.sender), "Not claimable.");
                addedReward = (ledger[epoch][msg.sender].amount * rounds[epoch].distributed) / (rounds[epoch].winnerBet);
            } else {
                require(refundable(_rounds[i], msg.sender), "Not refundable.");
                addedReward = ledger[epoch][msg.sender].amount;
            }

            ledger[_rounds[i]][msg.sender].claimed = true;
            reward += addedReward;
        }

        if (reward > 0) {
            _safeTransferCRO(msg.sender, reward);
        }
    }

    function claimTreasury() public onlyAdmin {
        require(treasuryAmount > 0, "Treasury is empty.");
        _safeTransferCRO(Admin, treasuryAmount);
        treasuryAmount = 0;
    }

    function setTreasuryFee(uint _value) public onlyAdmin {
        require(_value <= maxTreasuryFee);
        treasuryFee = _value;
    }

    function setInterval(uint _value) public onlyAdmin {
        interval = _value;
    }

    function setBuffer(uint _value) public onlyAdmin {
        buffer = _value;
    }

    function pause() external whenNotPaused onlyAdmin {
        _pause();
    }

    function unpause() external whenPaused onlyAdmin {
        genesisStartOnce = false;
        genesisLockOnce = false;
        _unpause();
    }

    function setMinBet(uint _amount) public onlyAdmin {
        minBet = _amount;
    }

    function setMaxBet(uint _amount) public onlyAdmin {
        maxBet = _amount;
    }

    function setAdmin(address _admin) public onlyAdmin {
        Admin = _admin;
    }

    function setOperator(address _operator) public onlyAdmin {
        Operator = _operator;
    }

    modifier onlyAdmin() {
        require(Admin == msg.sender, "Caller is not the admin.");
        _;
    }

    modifier onlyOperator() {
        require(Operator == msg.sender, "Caller is not the operator.");
        _;
    }
}