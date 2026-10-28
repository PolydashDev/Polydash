import { Header } from '@/components/header';
import { Footer } from '@/components/footer';
import { ExploreContent } from './_components/explore-content';

export default function HomePage() {
  return (
    <div className="min-h-screen flex flex-col bg-background">
      <Header />
      <main className="flex-1">
        <ExploreContent />
      </main>
      <Footer />
    </div>
  );
}
