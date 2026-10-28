import type { Wallet } from '@rainbow-me/rainbowkit';
import { metaMaskWallet, coinbaseWallet, trustWallet } from '@rainbow-me/rainbowkit/wallets';
import { createConnector } from 'wagmi';
import { injected } from 'wagmi/connectors';

type EthWindow = Window & { ethereum?: unknown };

function hasInjected(): boolean {
  return typeof window !== 'undefined' && typeof (window as EthWindow).ethereum !== 'undefined';
}

/**
 * A wallet that connects through the injected provider when one exists (desktop extension or the
 * wallet's in-app browser). Without one (e.g. mobile Safari/Chrome), it opens this page inside the
 * wallet app's browser via its official deep link, where the injected provider is available.
 * Needs no WalletConnect project ID.
 */
function deepLinkWallet(opts: {
  id: string;
  name: string;
  iconUrl: Wallet['iconUrl'];
  iconBackground: string;
  downloadUrls?: Wallet['downloadUrls'];
  buildUrl: (pageUrl: string) => string;
}): Wallet {
  return {
    id: opts.id,
    name: opts.name,
    iconUrl: opts.iconUrl,
    iconBackground: opts.iconBackground,
    downloadUrls: opts.downloadUrls,
    createConnector: (walletDetails) =>
      createConnector((config) => {
        const base = injected()(config);
        return {
          ...base,
          ...walletDetails,
          // RainbowKit calls getChainId() before connect(); without a provider it would throw and the
          // deep link would never open.
          async getChainId() {
            if (!hasInjected()) return config.chains[0].id;
            return base.getChainId();
          },
          async connect(params) {
            if (!hasInjected()) {
              window.location.href = opts.buildUrl(window.location.href);
              throw new Error(`Opening ${opts.name}…`);
            }
            return base.connect(params);
          },
        } as typeof base;
      }),
  };
}

export function buildDeepLinkWallets(): Wallet[] {
  // Reuse RainbowKit's official icons; the WalletConnect connectors behind these are never created.
  const ref = { projectId: 'unused', appName: 'Polypad' };
  const mm = metaMaskWallet(ref);
  const cb = coinbaseWallet({ appName: ref.appName });
  const tw = trustWallet(ref);

  return [
    deepLinkWallet({
      id: 'polydash-metamask',
      name: 'MetaMask',
      iconUrl: mm.iconUrl,
      iconBackground: mm.iconBackground,
      downloadUrls: mm.downloadUrls,
      buildUrl: (u) => `https://metamask.app.link/dapp/${u.replace(/^https?:\/\//, '')}`,
    }),
    deepLinkWallet({
      id: 'polydash-coinbase',
      name: 'Coinbase / Base',
      iconUrl: cb.iconUrl,
      iconBackground: cb.iconBackground,
      downloadUrls: cb.downloadUrls,
      buildUrl: (u) => `https://go.cb-w.com/dapp?cb_url=${encodeURIComponent(u)}`,
    }),
    deepLinkWallet({
      id: 'polydash-trust',
      name: 'Trust Wallet',
      iconUrl: tw.iconUrl,
      iconBackground: tw.iconBackground,
      downloadUrls: tw.downloadUrls,
      buildUrl: (u) => `https://link.trustwallet.com/open_url?coin_id=60&url=${encodeURIComponent(u)}`,
    }),
  ];
}
