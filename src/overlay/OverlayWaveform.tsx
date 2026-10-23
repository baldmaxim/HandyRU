import React, { useEffect, useRef } from "react";

// Scrolling level history: each bar is one sample of the mic level, newest on
// the right, older samples drifting left.
const BAR_COUNT = 11;
const BAR_MIN_PX = 4;
const BAR_MAX_PX = 22;
// Syllables run ~140-250ms; sampling faster lands neighbouring bars inside the
// same syllable and reads as a fluid ridge, so bars straddle onsets instead.
const SAMPLE_INTERVAL_MS = 80;

const barHeight = (level: number) =>
  BAR_MIN_PX +
  Math.pow(Math.min(1, Math.max(0, level) * 1.5), 0.85) *
    (BAR_MAX_PX - BAR_MIN_PX);

interface OverlayWaveformProps {
  /** Current smoothed mic level, 0..1. */
  getLevel: () => number;
  /** True once real microphone samples flow; false shows the arming pulse. */
  active: boolean;
}

// Heights are written straight to the DOM from a rAF loop, so recording never
// pays a React re-render per mic-level event.
const OverlayWaveform: React.FC<OverlayWaveformProps> = ({
  getLevel,
  active,
}) => {
  const barRefs = useRef<(HTMLElement | null)[]>([]);

  useEffect(() => {
    const paintAll = (levels: number[]) =>
      levels.forEach((level, i) => {
        const bar = barRefs.current[i];
        if (bar) bar.style.height = `${barHeight(level)}px`;
      });

    // A new capture starts from silence — never replay a previous session's wave.
    const levels: number[] = Array(BAR_COUNT).fill(0);
    paintAll(levels);
    if (!active) return;

    let frame = 0;
    let lastSample = 0;
    const paint = (now: number) => {
      if (now - lastSample >= SAMPLE_INTERVAL_MS) {
        lastSample = now;
        levels.shift();
        levels.push(getLevel());
        paintAll(levels);
      }
      frame = requestAnimationFrame(paint);
    };
    frame = requestAnimationFrame(paint);
    return () => cancelAnimationFrame(frame);
  }, [active, getLevel]);

  return (
    <div className={`swave ${active ? "ready" : "arming"}`} aria-hidden="true">
      {Array.from({ length: BAR_COUNT }, (_, i) => (
        <i
          key={i}
          ref={(el) => {
            barRefs.current[i] = el;
          }}
          // Arming ripple travels outward from the centre bar.
          style={{
            animationDelay: `${Math.abs(i - (BAR_COUNT - 1) / 2) * 70}ms`,
          }}
        />
      ))}
    </div>
  );
};

export default OverlayWaveform;
