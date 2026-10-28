import { connectorsForWallets, type WalletList } from '@rainbow-me/rainbowkit';
import { injectedWallet, rainbowWallet, walletConnectWallet } from '@rainbow-me/rainbowkit/wallets';
import { createConfig, http } from 'wagmi';
import { robinhoodChain } from './chain';
import { buildDeepLinkWallets } from './deep-link-wallets';

const appName = 'Polypad';
const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID ?? '';
const hasWalletConnect = projectId.length >= 32;

const wallets: WalletList = [
  { groupName: 'Popular', wallets: [
      ...buildDeepLinkWallets().map((w) => () => w),
      // Generic browser wallet: listed only when a provider is actually injected.
      () => ({
        ...injectedWallet(),
        installed: typeof window !== 'undefined' && typeof (window as Window & { ethereum?: unknown }).ethereum !== 'undefined',
      }),
    ],
  },
];
if (hasWalletConnect) {
  wallets.push({ groupName: 'More', wallets: [rainbowWallet, walletConnectWallet] });
}

const connectors = connectorsForWallets(wallets, {
  appName,
  // Only used by WalletConnect-based wallets, which are added only when a real ID is configured.
  projectId: hasWalletConnect ? projectId : 'unused',
});

export const wagmiConfig = createConfig({
  connectors,
  chains: [robinhoodChain],
  transports: {
    [robinhoodChain.id]: http(robinhoodChain.rpcUrls.default.http[0]),
  },
  ssr: true,
});
