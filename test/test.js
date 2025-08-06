const { ethers, deployments } = require("hardhat")

describe("测试合约的部署和升级", async function () {

    it("should deploy and upgrade the contract", async () => {
        // 部署合约(通过部署脚本中的tags来部署)
        await deployments.fixture("MetaNodeStakeV1")
        // 获取到合约地址(通过部署脚本中的save方法得到名字)
        const metaNodeStakeV1 = await deployments.get("MetaNodeStakeV1")
        // 创建合约实例
        const metaNodeStakeV1Contract = await ethers.getContractAt("MetaNodeStake", metaNodeStakeV1.address)
        // 调用合约中的方法.....

        // 升级合约(通过部署脚本中的tags来部署)
        await deployments.fixture("MetaNodeStakeV2")

        // 对比升级后的合约和原始合约中的状态是否保持一致
    })
})
