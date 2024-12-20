import assert from 'assert';
import { type DeployFunction } from 'hardhat-deploy/types';

const contractName = 'MemeverseRegistrarOnBlast';

const deploy: DeployFunction = async (hre) => {
    const { getNamedAccounts, deployments } = hre;

    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    assert(deployer, 'Missing named deployer account');

    console.log(`Network: ${hre.network.name}`);
    console.log(`Deployer: ${deployer}`);

    const outrunDeployerABI = [
        "function deploy(bytes32 salt, bytes memory creationCode) external payable returns (address deployed)",
        "function getDeployed(address deployer, bytes32 salt) external view returns (address)"
    ];
    const outrunDeployerAddress = process.env.OUTRUN_DEPLOYER as string;
    const signer = await hre.ethers.getSigner(deployer);
    const outrunDeployer = new hre.ethers.Contract(outrunDeployerAddress, outrunDeployerABI, signer);
    
    const constructorArgs = [
        process.env.OWNER,
        process.env.BLAST_GOVERNOR,
        process.env.BLAST_SEPOLIA_ENDPOINT,
        process.env.MEMECOIN_DEPLOYER,
        process.env.LIQUID_PROOF_DEPLOYER,
        20000000, 
        2000000,
        process.env.BLAST_SEPOLIA_EID
    ];

    const salt = hre.ethers.utils.keccak256(hre.ethers.utils.solidityPack(
        ["string", "uint256"],
        ["MemeverseRegistrar", 3]
    ));
    const creationCode = await hre.artifacts.readArtifact(contractName);
    const encodedArgs = hre.ethers.utils.defaultAbiCoder.encode(
        ['address', 'address', 'address', 'address', 'address', 'address', 'uint128', 'uint128', 'uint32'],
        constructorArgs
    );
    const bytecodeWithArgs = creationCode.bytecode + encodedArgs.slice(2);
    await outrunDeployer.deploy(salt, bytecodeWithArgs, { value: hre.ethers.utils.parseEther('0') });
    const deployedAddress = await outrunDeployer.getDeployed(deployer, salt);
    console.log(`Deployed contract: ${contractName}, network: ${hre.network.name}, address: ${deployedAddress}`)
    
    await deployments.save(contractName, {
        address: deployedAddress,
        abi: creationCode.abi
    });

    // Verifying contract
    let count = 0;
    do {
        try {
            console.log(`Verifying contract ${contractName} on ${hre.network.name}, address: ${deployedAddress}`);
            await hre.run("verify:verify", {
                address: deployedAddress,
                constructorArguments: constructorArgs,
            });
            console.log(`Contract: ${contractName} on ${hre.network.name} verified!, address: ${deployedAddress}`);
            count = 10;
        } catch (err) {
            count++;
            console.error(`Contract: ${contractName} on ${hre.network.name} verification failed!, address: ${deployedAddress}`, err);
        }
    } while (count < 10);
}

deploy.tags = ["MemeverseRegistrarOnBlast"]

export default deploy
