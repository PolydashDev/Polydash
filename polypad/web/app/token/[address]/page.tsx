import { Header } from '@/components/header';
import { Footer } from '@/components/footer';
import { TokenDetailContent } from './_components/token-detail-content';

export default async function TokenPage({ params }: { params: Promise<{ address: string }> }) {
  const { address } = await params;
  return (
    <div className="min-h-screen flex flex-col bg-background">
      <Header />
      <main className="flex-1">
        <TokenDetailContent address={address} />
      </main>
      <Footer />
    </div>
  );
}
