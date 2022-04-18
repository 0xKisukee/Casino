// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
}

interface ICASINO {
    function executeClaim(address _user, uint256 _amount) external;
    function addToTreasury(uint256 _amount) external;
    function addWagered(address _user, uint256 _amount) external;
}

contract ChickenSC {
    constructor(address _casino, address _token, address _admin, address _operator) {
        token = _token;
        casino = _casino;
        admin = _admin;
        operator = _operator;
    }

    struct Grid {
        uint gridId;
        bool isStarted;
        bool isEnded;
        uint boneSquare;
    }

    struct GridInfo {
        uint[9] squares;
        uint amount;
        bool claimed;
    }

    uint currentRound;
    uint treasuryFee = 250;     // 2.5%
    uint maxTreasuryFee = 1000; // 10%
    uint minBet = 50;
    uint maxBet = 1000;
    uint[8] payouts = [110, 120, 150, 180, 220, 300, 450, 900]; // Divide by 100

    // Token used by the game
    address token;
    
    // Casino smart contract address
    address casino;

    // Admin address
    address admin;

    // Rounds executor (has to be automated)
    address operator;

    mapping (uint => Grid) public grids;
    mapping (address => uint) public lastGrid;
    mapping (uint => mapping(address => GridInfo)) public ledger;

    function executeRound() public onlyOperator {

        grids[currentRound].isEnded = true;
        grids[currentRound].boneSquare = block.timestamp % 9;

        currentRound += 1;

        grids[currentRound].gridId = currentRound;
        grids[currentRound].isStarted = true;
    }

    function createGrid(uint _amount, uint[9] memory _squares) public {
        require(_amount >= minBet && _amount <= maxBet, "Bet amount not valid.");
        require(lastGrid[msg.sender] == 0, "You can't submit a grid before claiming the last.");
        require(calculateSquareAmount(_squares) > 0, "You have to select at least 1 square.");
        require(calculateSquareAmount(_squares) < 9, "You can't select all the squares.");

        IERC20(token).transferFrom(msg.sender, casino, _amount);
        ICASINO(casino).addWagered(msg.sender, _amount);

        uint fees = _amount * treasuryFee / 100000;
        ICASINO(casino).addToTreasury(fees);

        lastGrid[msg.sender] = currentRound;

        ledger[currentRound][msg.sender].squares = _squares;
        ledger[currentRound][msg.sender].amount = _amount;
    }

    function claimable(uint _round, address _user) public view returns (bool) {
        uint boneSquare = grids[_round].boneSquare;
    
        return
            (ledger[_round][_user].amount != 0 &&
            ledger[_round][_user].claimed == false &&
            ledger[_round][_user].squares[boneSquare] == 0 &&
            grids[_round].isEnded);
    }

    function calculateSquareAmount(uint[9] memory _squares) public pure returns (uint squareAmount) {
        for (uint i = 0; i < 9; i++) {
            if (_squares[i] == 1) {
                squareAmount++;
            }
        }
    }

    function claim() public {
        uint round = lastGrid[msg.sender];

        require(claimable(round, msg.sender), "Not claimable.");

        uint squareAmount = calculateSquareAmount(ledger[round][msg.sender].squares);
        uint amountBet = ledger[round][msg.sender].amount;
        uint reward = amountBet * payouts[squareAmount-1] / 100;

        ledger[round][msg.sender].claimed = true;
        lastGrid[msg.sender] = 0;

        uint fees = reward * treasuryFee / 100000;
        ICASINO(casino).executeClaim(msg.sender, reward - fees);
    }

    function setMinBet(uint _amount) public onlyAdmin {
        minBet = _amount;
    }

    function setMaxBet(uint _amount) public onlyAdmin {
        maxBet = _amount;
    }

    function setAdmin(address _admin) public onlyAdmin {
        admin = _admin;
    }

    function setOperator(address _operator) public onlyAdmin {
        operator = _operator;
    }

    modifier onlyAdmin() {
        require(admin == msg.sender, "Caller is not the admin.");
        _;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "Caller is not the operator.");
        _;
    }
}