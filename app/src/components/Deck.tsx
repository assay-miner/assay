import { useState, type ReactNode } from "react";

/**
 * A paginated deck. The mechanism does not fit on one screen and should not become a scroll —
 * each argument gets its own plate, advanced by the dots below.
 */
export default function Deck({ slides, label }: { slides: ReactNode[]; label: string }) {
  const [i, setI] = useState(0);
  return (
    <div className="deck">
      {slides[i]}
      <div className="deck-dots" role="tablist" aria-label={label}>
        {slides.map((_, n) => (
          <button
            key={n}
            role="tab"
            aria-current={n === i}
            aria-label={`${label} ${n + 1}`}
            onClick={() => setI(n)}
          />
        ))}
      </div>
    </div>
  );
}
