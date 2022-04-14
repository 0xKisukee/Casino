// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract CasinoSC {
    constructor(address _admin, address _token) {
        admin = _admin;
        token = _token;
    }

    struct UserInfo {
        uint wagered;
    }

    // Users infos
    mapping(address => UserInfo) userInfo;

    // Authorized games
    mapping(address => bool) isAuthGame;

    // Admin address
    address admin;

    // Token used by the casino
    address token;

    // Treasury of the team
    uint256 treasury;

    // Called by games to pay players when they claim their earnings
    function executeClaim(address _user, uint256 _amount) public onlyAuthGames {
        IERC20(token).transfer(_user, _amount);
    }

    // Called by games to update fees going to the team treasury
    function addToTreasury(uint256 _amount) public onlyAuthGames {
        treasury += _amount;
    }

    // Called by games to update the total amount wagered by a user
    function addWagered(address _user, uint256 _amount) public onlyAuthGames {
        userInfo[_user].wagered += _amount;
    }

    // Called by admin when he authorizes a game SC to use restricted functions
    function authorizeGame(address _game) public onlyAdmin {
        require(isAuthGame[_game] == false, "Games is already authorized.");
        isAuthGame[_game] = true;
    }

    // Called by admin when he bans a game SC from restricted functions
    function banGame(address _game) public onlyAdmin {
        require(isAuthGame[_game] == true, "Games is already banned.");
        isAuthGame[_game] = false;
    }

    // Called by admin the withdraw the treasury amounts in his wallet
    function withdrawTreasury() public onlyAdmin {
        IERC20(token).transfer(admin, treasury);
        treasury = 0;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Caller is not the admin.");
        _;
    }

    modifier onlyAuthGames() {
        require(
            isAuthGame[msg.sender] == true,
            "Caller is not an authorized game."
        );
        _;
    }
}
