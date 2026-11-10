"use client";

// Event search as the app shows it: a search field, and questions to try in it.
import { useState } from "react";

const questions = [
  "a courier at the front door this week",
  "a man in a red jacket last night",
  "a cat in the backyard",
  "a white van on the driveway",
];

export function SearchExamples() {
  const [question, setQuestion] = useState(questions[0]);
  return (
    <>
      <div className="search" role="img" aria-label={`Pond’s event search: ${question}`}>
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
          <circle cx="11" cy="11" r="7" />
          <path d="m20 20-3.5-3.5" />
        </svg>
        <output>{question}</output>
      </div>
      <div className="queries" role="group" aria-label="Example searches">
        {questions.map((q) => (
          <button type="button" key={q} aria-pressed={q === question} onClick={() => setQuestion(q)}>
            {q}
          </button>
        ))}
      </div>
    </>
  );
}
