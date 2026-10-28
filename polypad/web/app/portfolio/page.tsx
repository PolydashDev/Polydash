import { Header } from '@/components/header';
import { Footer } from '@/components/footer';
import { PortfolioContent } from './_components/portfolio-content';

export default function PortfolioPage() {
  return (
    <div className="min-h-screen flex flex-col bg-background">
      <Header />
      <main className="flex-1">
        <PortfolioContent />
      </main>
      <Footer />
    </div>
  );
}
