import { Header } from '@/components/header';
import { Footer } from '@/components/footer';
import { LeaderboardContent } from './_components/leaderboard-content';

export default function LeaderboardPage() {
  return (
    <div className="min-h-screen flex flex-col bg-background">
      <Header />
      <main className="flex-1">
        <LeaderboardContent />
      </main>
      <Footer />
    </div>
  );
}
