// SPDX-License-Identifier: MIT
// 声明合约使用的Solidity版本（0.8.20包含溢出检查等安全特性）
pragma solidity ^0.8.20;

// 基础依赖库
import "@openzeppelin/contracts/token/ERC20/IERC20.sol"; // ERC20标准接口
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol"; // 安全的ERC20操作
import "@openzeppelin/contracts/utils/Address.sol"; // 地址工具类
import "@openzeppelin/contracts/utils/math/Math.sol"; // 安全数学运算

// 可升级合约依赖
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol"; // 可初始化合约
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol"; // UUPS升级模式
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol"; // 基于角色的权限控制
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol"; // 可暂停功能

// 主合约声明（继承可升级、可暂停、权限控制等特性）
contract MetaNodeStake is
    Initializable, // 初始化支持
    UUPSUpgradeable, // UUPS代理升级支持
    PausableUpgradeable, // 紧急暂停功能
    AccessControlUpgradeable // 角色权限管理
{
    // 安全库应用
    using SafeERC20 for IERC20; // 为IERC20添加安全操作（防止重入等）
    using Address for address; // 为地址类型添加工具方法
    using Math for uint256; // 为uint256添加安全数学方法

    // ===================== 常量定义 =====================
    bytes32 public constant ADMIN_ROLE = keccak256("admin_role"); // 管理员角色（配置参数）
    bytes32 public constant UPGRADE_ROLE = keccak256("upgrade_role"); // 升级角色
    uint256 public constant nativeCurrency_PID = 0; // 原生代币池ID（0表示ETH/BNB等）

    // ===================== 数据结构 =====================
    /**
     * 质押池结构体
     * @param stTokenAddress 质押代币地址（0x0表示原生代币）
     * @param poolWeight 池权重（奖励分配比例）
     * @param lastRewardBlock 最后奖励区块
     * @param accMetaNodePerST 每单位质押代币累积奖励（精度1e18）
     * @param stTokenAmount 池中质押代币总量
     * @param minDepositAmount 最小质押量（防粉尘攻击）
     * @param unstakeLockedBlocks 解锁所需区块数（质押锁定期）
     */
    struct Pool {
        address stTokenAddress;
        uint256 poolWeight;
        uint256 lastRewardBlock;
        uint256 accMetaNodePerST;
        uint256 stTokenAmount;
        uint256 minDepositAmount;
        uint256 unstakeLockedBlocks;
    }

    /**
     * 解锁请求结构体
     * @param amount 请求解锁数量
     * @param unlockBlocks 可解锁的区块高度
     */
    struct UnstakeRequest {
        uint256 amount;
        uint256 unlockBlocks;
    }

    /**
     * 用户信息结构体
     * @param stAmount 用户质押总量
     * @param finishedMetaNode 已结算的奖励
     * @param pendingMetaNode 待领取的奖励
     * @param requests 解锁请求队列（FIFO）
     */
    struct User {
        uint256 stAmount;
        uint256 finishedMetaNode;
        uint256 pendingMetaNode;
        UnstakeRequest[] requests; // 动态数组存储解锁请求
    }

    // ===================== 状态变量 =====================
    uint256 public startBlock; // 奖励开始区块
    uint256 public endBlock; // 奖励结束区块
    uint256 public MetaNodePerBlock; // 每区块奖励数量

    bool public withdrawPaused; // 提现暂停标志
    bool public claimPaused; // 领取奖励暂停标志

    IERC20 public MetaNode; // 奖励代币合约

    uint256 public totalPoolWeight; // 总池权重（用于奖励分配）
    Pool[] public pool; // 质押池数组

    // 嵌套映射：池ID => 用户地址 => 用户信息
    mapping(uint256 => mapping(address => User)) public user;

    // ===================== 事件定义 =====================
    event SetMetaNode(IERC20 indexed MetaNode); // 奖励代币更新
    event PauseWithdraw(); // 提现暂停
    event UnpauseWithdraw(); // 提现恢复
    event PauseClaim(); // 领取暂停
    event UnpauseClaim(); // 领取恢复
    event SetStartBlock(uint256 indexed startBlock); // 开始区块更新
    event SetEndBlock(uint256 indexed endBlock); // 结束区块更新
    event SetMetaNodePerBlock(uint256 indexed MetaNodePerBlock); // 区块奖励更新
    event AddPool(
        address indexed stTokenAddress,
        uint256 indexed poolWeight,
        uint256 indexed lastRewardBlock,
        uint256 minDepositAmount,
        uint256 unstakeLockedBlocks
    ); // 新池添加
    event UpdatePoolInfo(
        uint256 indexed poolId,
        uint256 indexed minDepositAmount,
        uint256 indexed unstakeLockedBlocks
    ); // 池参数更新
    event SetPoolWeight(
        uint256 indexed poolId,
        uint256 indexed poolWeight,
        uint256 totalPoolWeight
    ); // 池权重更新
    event UpdatePool(
        uint256 indexed poolId,
        uint256 indexed lastRewardBlock,
        uint256 totalMetaNode
    ); // 池奖励更新
    event Deposit(address indexed user, uint256 indexed poolId, uint256 amount); // 存款事件
    event RequestUnstake(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount
    ); // 解锁请求
    event Withdraw(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount,
        uint256 indexed blockNumber
    ); // 提现完成
    event Claim(
        address indexed user,
        uint256 indexed poolId,
        uint256 MetaNodeReward
    ); // 奖励领取

    // ===================== 修饰器 =====================
    modifier checkPid(uint256 _pid) {
        require(_pid < pool.length, "invalid pid"); // 检查池ID有效性
        _;
    }

    modifier whenNotClaimPaused() {
        require(!claimPaused, "claim is paused"); // 检查领取功能是否暂停
        _;
    }

    modifier whenNotWithdrawPaused() {
        require(!withdrawPaused, "withdraw is paused"); // 检查提现功能是否暂停
        _;
    }

    // ===================== 初始化函数 =====================
    /**
     * 合约初始化（代理合约的构造函数替代）
     * @param _MetaNode 奖励代币地址
     * @param _startBlock 奖励开始区块
     * @param _endBlock 奖励结束区块
     * @param _MetaNodePerBlock 每区块奖励数量
     */
    function initialize(
        IERC20 _MetaNode,
        uint256 _startBlock,
        uint256 _endBlock,
        uint256 _MetaNodePerBlock
    ) public initializer {
        require(
            _startBlock <= _endBlock && _MetaNodePerBlock > 0,
            "invalid parameters"
        );

        // 初始化父合约
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __Pausable_init();

        // 授予部署者默认角色
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(UPGRADE_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        setMetaNode(_MetaNode); // 设置奖励代币

        // 初始化核心参数
        startBlock = _startBlock;
        endBlock = _endBlock;
        MetaNodePerBlock = _MetaNodePerBlock;
    }

    /**
     * UUPS升级授权检查
     * @param newImplementation 新实现地址
     */
    function _authorizeUpgrade(
        address newImplementation
    )
        internal
        override
        onlyRole(UPGRADE_ROLE) // 仅升级角色可调用
    {}

    // ===================== 管理功能 =====================
    /// @notice 设置奖励代币合约（仅管理员）
    function setMetaNode(IERC20 _MetaNode) public onlyRole(ADMIN_ROLE) {
        MetaNode = _MetaNode;
        emit SetMetaNode(MetaNode);
    }

    /// @notice 暂停提现功能（仅管理员）
    function pauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(!withdrawPaused, "withdraw has been already paused");
        withdrawPaused = true;
        emit PauseWithdraw();
    }

    /// @notice 恢复提现功能（仅管理员）
    function unpauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(withdrawPaused, "withdraw has been already unpaused");
        withdrawPaused = false;
        emit UnpauseWithdraw();
    }

    /// @notice 暂停奖励领取（仅管理员）
    function pauseClaim() public onlyRole(ADMIN_ROLE) {
        require(!claimPaused, "claim has been already paused");
        claimPaused = true;
        emit PauseClaim();
    }

    /// @notice 恢复奖励领取（仅管理员）
    function unpauseClaim() public onlyRole(ADMIN_ROLE) {
        require(claimPaused, "claim has been already unpaused");
        claimPaused = false;
        emit UnpauseClaim();
    }

    /// @notice 更新奖励开始区块（需≤结束区块）
    function setStartBlock(uint256 _startBlock) public onlyRole(ADMIN_ROLE) {
        require(
            _startBlock <= endBlock,
            "start block must be smaller than end block"
        );
        startBlock = _startBlock;
        emit SetStartBlock(_startBlock);
    }

    /// @notice 更新奖励结束区块（需≥开始区块）
    function setEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE) {
        require(
            startBlock <= _endBlock,
            "start block must be smaller than end block"
        );
        endBlock = _endBlock;
        emit SetEndBlock(_endBlock);
    }

    /// @notice 更新每区块奖励数量（必须>0）
    function setMetaNodePerBlock(
        uint256 _MetaNodePerBlock
    ) public onlyRole(ADMIN_ROLE) {
        require(_MetaNodePerBlock > 0, "invalid parameter");
        MetaNodePerBlock = _MetaNodePerBlock;
        emit SetMetaNodePerBlock(_MetaNodePerBlock);
    }

    /**
     * @notice 添加新质押池（仅管理员）
     * @dev 第一个池必须是原生代币池（stTokenAddress=0）
     * @param _stTokenAddress 质押代币地址
     * @param _poolWeight 池权重
     * @param _minDepositAmount 最小质押量
     * @param _unstakeLockedBlocks 解锁区块数
     * @param _withUpdate 是否更新所有池
     */
    function addPool(
        address _stTokenAddress,
        uint256 _poolWeight,
        uint256 _minDepositAmount,
        uint256 _unstakeLockedBlocks,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) {
        // 第一个池必须是原生代币池
        if (pool.length > 0) {
            require(
                _stTokenAddress != address(0),
                "invalid staking token address"
            );
        } else {
            require(
                _stTokenAddress == address(0),
                "invalid staking token address"
            );
        }

        require(_unstakeLockedBlocks > 0, "invalid withdraw locked blocks");
        require(block.number < endBlock, "Already ended");

        // 若需更新，先更新所有池状态
        if (_withUpdate) massUpdatePools();

        // 计算最后奖励区块（取当前区块和开始区块的最大值）
        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;

        // 更新总权重
        totalPoolWeight += _poolWeight;

        // 创建新池
        pool.push(
            Pool({
                stTokenAddress: _stTokenAddress,
                poolWeight: _poolWeight,
                lastRewardBlock: lastRewardBlock,
                accMetaNodePerST: 0,
                stTokenAmount: 0,
                minDepositAmount: _minDepositAmount,
                unstakeLockedBlocks: _unstakeLockedBlocks
            })
        );

        emit AddPool(
            _stTokenAddress,
            _poolWeight,
            lastRewardBlock,
            _minDepositAmount,
            _unstakeLockedBlocks
        );
    }

    /// @notice 更新池参数（仅管理员）
    function updatePool(
        uint256 _pid,
        uint256 _minDepositAmount,
        uint256 _unstakeLockedBlocks
    ) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        pool[_pid].minDepositAmount = _minDepositAmount;
        pool[_pid].unstakeLockedBlocks = _unstakeLockedBlocks;
        emit UpdatePoolInfo(_pid, _minDepositAmount, _unstakeLockedBlocks);
    }

    /// @notice 更新池权重（仅管理员）
    function setPoolWeight(
        uint256 _pid,
        uint256 _poolWeight,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) checkPid(_pid) {
        require(_poolWeight > 0, "invalid pool weight");

        // 若需更新，先更新所有池
        if (_withUpdate) massUpdatePools();

        // 更新总权重（先减旧权重再加新权重）
        totalPoolWeight = totalPoolWeight - pool[_pid].poolWeight + _poolWeight;
        pool[_pid].poolWeight = _poolWeight;

        emit SetPoolWeight(_pid, _poolWeight, totalPoolWeight);
    }

    // ===================== 查询功能 =====================
    /// @notice 获取池数量
    function poolLength() external view returns (uint256) {
        return pool.length;
    }

    /**
     * @notice 计算两个区块间的奖励乘数
     * @param _from 起始区块（包含）
     * @param _to 结束区块（不包含）
     * @return multiplier 奖励乘数 = (_to - _from) * MetaNodePerBlock
     */
    function getMultiplier(
        uint256 _from,
        uint256 _to
    ) public view returns (uint256 multiplier) {
        require(_from <= _to, "invalid block range");

        // 边界处理（不超过开始/结束区块）
        if (_from < startBlock) _from = startBlock;
        if (_to > endBlock) _to = endBlock;
        require(_from <= _to, "end block must be greater than start block");

        // 安全计算区块差*每区块奖励
        (bool success, uint256 blocks) = (_to - _from).tryMul(MetaNodePerBlock);
        require(success, "multiplier overflow");
        return blocks;
    }

    /// @notice 获取用户待领取奖励（当前区块）
    function pendingMetaNode(
        uint256 _pid,
        address _user
    ) external view checkPid(_pid) returns (uint256) {
        return pendingMetaNodeByBlockNumber(_pid, _user, block.number);
    }

    /**
     * @notice 获取用户在特定区块高度的待领取奖励
     * @dev 计算公式：待领取 = (质押量 * 单位累积奖励) - 已结算奖励 + 待处理奖励
     */
    function pendingMetaNodeByBlockNumber(
        uint256 _pid,
        address _user,
        uint256 _blockNumber
    ) public view checkPid(_pid) returns (uint256) {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][_user];

        uint256 accMetaNodePerST = pool_.accMetaNodePerST;
        uint256 stSupply = pool_.stTokenAmount;

        // 若查询区块高于最后奖励区块且池中有质押量
        if (_blockNumber > pool_.lastRewardBlock && stSupply != 0) {
            // 计算新增奖励 = 奖励乘数 * 池权重 / 总权重
            uint256 multiplier = getMultiplier(
                pool_.lastRewardBlock,
                _blockNumber
            );
            uint256 MetaNodeForPool = (multiplier * pool_.poolWeight) /
                totalPoolWeight;

            // 更新单位累积奖励 = 原累积 + (新增奖励 * 1e18 / 池质押总量)
            accMetaNodePerST += (MetaNodeForPool * 1 ether) / stSupply;
        }

        // 最终计算：质押量*单位累积奖励 - 已结算奖励 + 待处理奖励
        return
            ((user_.stAmount * accMetaNodePerST) / 1 ether) -
            user_.finishedMetaNode +
            user_.pendingMetaNode;
    }

    /// @notice 获取用户质押量
    function stakingBalance(
        uint256 _pid,
        address _user
    ) external view checkPid(_pid) returns (uint256) {
        return user[_pid][_user].stAmount;
    }

    /// @notice 获取用户解锁请求信息
    function withdrawAmount(
        uint256 _pid,
        address _user
    )
        public
        view
        checkPid(_pid)
        returns (uint256 requestAmount, uint256 pendingWithdrawAmount)
    {
        User storage user_ = user[_pid][_user];

        // 遍历所有解锁请求
        for (uint256 i = 0; i < user_.requests.length; i++) {
            // 统计总请求量
            requestAmount += user_.requests[i].amount;

            // 统计已解锁量（当前区块≥解锁区块）
            if (user_.requests[i].unlockBlocks <= block.number) {
                pendingWithdrawAmount += user_.requests[i].amount;
            }
        }
    }

    // ===================== 用户操作 =====================
    /**
     * @notice 更新单个池的奖励状态
     * @dev 核心逻辑：计算新增奖励并更新单位累积值
     */
    function updatePool(uint256 _pid) public checkPid(_pid) {
        Pool storage pool_ = pool[_pid];

        // 若当前区块≤最后奖励区块，无需更新
        if (block.number <= pool_.lastRewardBlock) return;

        // 安全计算：新增奖励 = 奖励乘数 * 池权重 / 总权重
        (bool success, uint256 totalMetaNode) = getMultiplier(
            pool_.lastRewardBlock,
            block.number
        ).tryMul(pool_.poolWeight);
        require(success, "totalMetaNode mul overflow");

        (success, totalMetaNode) = totalMetaNode.tryDiv(totalPoolWeight);
        require(success, "totalMetaNode div overflow");

        uint256 stSupply = pool_.stTokenAmount;
        if (stSupply > 0) {
            // 计算单位奖励增量 = 新增奖励 * 1e18 / 池质押总量
            uint256 rewardPerST;
            (success, rewardPerST) = totalMetaNode.tryMul(1 ether);
            require(success, "rewardPerST mul overflow");

            (success, rewardPerST) = rewardPerST.tryDiv(stSupply);
            require(success, "rewardPerST div overflow");

            // 更新单位累积奖励（带溢出检查）
            uint256 newAcc;
            (success, newAcc) = pool_.accMetaNodePerST.tryAdd(rewardPerST);
            require(success, "acc overflow");
            pool_.accMetaNodePerST = newAcc;
        }

        // 更新最后奖励区块
        pool_.lastRewardBlock = block.number;
        emit UpdatePool(_pid, pool_.lastRewardBlock, totalMetaNode);
    }

    /// @notice 更新所有池状态（高Gas消耗）
    function massUpdatePools() public {
        uint256 length = pool.length;
        for (uint256 pid = 0; pid < length; pid++) {
            updatePool(pid);
        }
    }

    /// @notice 质押原生代币（如ETH）
    function depositnativeCurrency() public payable whenNotPaused {
        Pool storage pool_ = pool[nativeCurrency_PID];
        require(pool_.stTokenAddress == address(0), "invalid staking token");

        uint256 amount = msg.value;
        require(amount >= pool_.minDepositAmount, "deposit too small");

        _deposit(nativeCurrency_PID, amount); // 调用内部存款逻辑
    }

    /**
     * @notice 质押ERC20代币
     * @dev 需先授权合约操作代币
     */
    function deposit(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) {
        require(_pid != 0, "nativeCurrency staking not here");
        Pool storage pool_ = pool[_pid];
        require(_amount >= pool_.minDepositAmount, "deposit too small");

        if (_amount > 0) {
            // 安全转账（需预先授权）
            IERC20(pool_.stTokenAddress).safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
        }

        _deposit(_pid, _amount);
    }

    /**
     * @notice 发起解锁请求（非即时到账）
     * @dev 质押量减少，但资金需等待解锁期
     */
    function unstake(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        require(user_.stAmount >= _amount, "insufficient balance");
        updatePool(_pid); // 更新奖励状态

        // 计算待领取奖励
        uint256 pending = ((user_.stAmount * pool_.accMetaNodePerST) /
            1 ether) - user_.finishedMetaNode;
        if (pending > 0) {
            user_.pendingMetaNode += pending; // 累加到待领取
        }

        if (_amount > 0) {
            // 更新用户质押量
            user_.stAmount -= _amount;

            // 添加解锁请求（解锁区块 = 当前区块 + 锁定区块）
            user_.requests.push(
                UnstakeRequest({
                    amount: _amount,
                    unlockBlocks: block.number + pool_.unstakeLockedBlocks
                })
            );
        }

        // 更新池质押总量
        pool_.stTokenAmount -= _amount;

        // 重置已结算奖励（基于新质押量）
        user_.finishedMetaNode =
            (user_.stAmount * pool_.accMetaNodePerST) /
            1 ether;

        emit RequestUnstake(msg.sender, _pid, _amount);
    }

    /// @notice 提取已解锁的资金
    function withdraw(
        uint256 _pid
    ) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        uint256 pendingWithdraw;
        uint256 popCount;

        // 遍历解锁请求
        for (uint256 i = 0; i < user_.requests.length; i++) {
            // 遇到未解锁请求则停止（请求按解锁时间排序）
            if (user_.requests[i].unlockBlocks > block.number) break;

            // 累加已解锁量
            pendingWithdraw += user_.requests[i].amount;
            popCount++; // 记录待移除请求数
        }

        // 移除已处理的请求（高效数组操作）
        if (popCount > 0) {
            uint256 remain = user_.requests.length - popCount;

            // 前移剩余请求
            for (uint256 i = 0; i < remain; i++) {
                user_.requests[i] = user_.requests[i + popCount];
            }

            // 弹出已处理请求
            for (uint256 i = 0; i < popCount; i++) {
                user_.requests.pop();
            }
        }

        // 转账已解锁资金
        if (pendingWithdraw > 0) {
            if (pool_.stTokenAddress == address(0)) {
                _safenativeCurrencyTransfer(msg.sender, pendingWithdraw); // 转原生代币
            } else {
                IERC20(pool_.stTokenAddress).safeTransfer(
                    msg.sender,
                    pendingWithdraw
                ); // 转ERC20代币
            }
        }

        emit Withdraw(msg.sender, _pid, pendingWithdraw, block.number);
    }

    /// @notice 领取奖励代币
    function claim(
        uint256 _pid
    ) public whenNotPaused checkPid(_pid) whenNotClaimPaused {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        updatePool(_pid); // 更新奖励状态

        // 计算总待领取 = (质押量*单位奖励 - 已结算) + 待处理
        uint256 pending = ((user_.stAmount * pool_.accMetaNodePerST) /
            1 ether) -
            user_.finishedMetaNode +
            user_.pendingMetaNode;

        if (pending > 0) {
            user_.pendingMetaNode = 0; // 清零待处理

            // 安全转账奖励代币
            _safeMetaNodeTransfer(msg.sender, pending);
        }

        // 更新已结算奖励
        user_.finishedMetaNode =
            (user_.stAmount * pool_.accMetaNodePerST) /
            1 ether;

        emit Claim(msg.sender, _pid, pending);
    }

    // ===================== 内部函数 =====================
    /**
     * @notice 存款核心逻辑
     * @dev 处理奖励计算和状态更新
     */
    function _deposit(uint256 _pid, uint256 _amount) internal {
        Pool storage pool_ = pool[_pid];
        User storage user_ = user[_pid][msg.sender];

        updatePool(_pid); // 更新池状态

        // 若用户已有质押，计算待领取奖励
        if (user_.stAmount > 0) {
            // 计算应得奖励 = (质押量 * 单位累积奖励) / 1e18
            (bool success1, uint256 reward) = user_.stAmount.tryMul(
                pool_.accMetaNodePerST
            );
            require(success1, "reward calc overflow");

            (success1, reward) = reward.tryDiv(1 ether);
            require(success1, "reward precision error");

            // 待领取 = 应得奖励 - 已结算
            uint256 pending;
            (success1, pending) = reward.trySub(user_.finishedMetaNode);
            require(success1, "pending calc error");

            if (pending > 0) {
                // 累加到待领取余额
                (success1, user_.pendingMetaNode) = user_
                    .pendingMetaNode
                    .tryAdd(pending);
                require(success1, "pending overflow");
            }
        }

        // 更新用户质押量
        if (_amount > 0) {
            (bool success2, uint256 newBalance) = user_.stAmount.tryAdd(
                _amount
            );
            require(success2, "balance overflow");
            user_.stAmount = newBalance;

            // 更新池质押总量
            (success2, pool_.stTokenAmount) = pool_.stTokenAmount.tryAdd(
                _amount
            );
            require(success2, "pool balance overflow");
        }

        // 重新计算已结算奖励（基于新质押量）
        (bool success, uint256 newFinished) = user_.stAmount.tryMul(
            pool_.accMetaNodePerST
        );
        require(success, "finished calc overflow");

        (success, newFinished) = newFinished.tryDiv(1 ether);
        require(success, "finished precision error");

        user_.finishedMetaNode = newFinished;

        emit Deposit(msg.sender, _pid, _amount);
    }

    /// @notice 安全转账奖励代币（防合约余额不足）
    function _safeMetaNodeTransfer(address _to, uint256 _amount) internal {
        uint256 balance = MetaNode.balanceOf(address(this));
        if (_amount > balance) {
            MetaNode.transfer(_to, balance); // 转实际余额
        } else {
            MetaNode.transfer(_to, _amount); // 转全部金额
        }
    }

    /// @notice 安全转账原生代币（带结果检查）
    function _safenativeCurrencyTransfer(
        address _to,
        uint256 _amount
    ) internal {
        (bool success, bytes memory data) = _to.call{value: _amount}("");
        require(success, "transfer failed");

        // 若接收者是合约，检查其返回值
        if (data.length > 0) {
            require(abi.decode(data, (bool)), "contract transfer failed");
        }
    }
}
