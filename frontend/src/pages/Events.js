import React, { useState, useEffect } from 'react';
import { Link } from 'react-router-dom';
import axios from 'axios';
import API_CONFIG from '../config/api';
import './Events.css';

function Events() {
  const [events, setEvents] = useState([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [category, setCategory] = useState('');
  const [debouncedSearch, setDebouncedSearch] = useState(search);

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedSearch(search), 500);
    return () => clearTimeout(timer);
  }, [search]);

  useEffect(() => {
    fetchEvents();
  }, [debouncedSearch, category]);

  const fetchEvents = async () => {
    try {
      let url = `${API_CONFIG.event}/events`;
      const params = [];
      if (search) params.push(`search=${search}`);
      if (category) params.push(`category=${category}`);
      if (params.length) url += `?${params.join('&')}`;

      const response = await axios.get(url);
      setEvents(response.data.events);
    } catch (err) {
      console.error('Error fetching events:', err);
    } finally {
      setLoading(false);
    }
  };

  if (loading) return <div className="loading">Loading events...</div>;

  return (
    <div className="events-page">
      <h1>Upcoming Events</h1>
      
      <div className="filters">
        <input
          type="text"
          placeholder="Search events..."
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
        <select value={category} onChange={(e) => setCategory(e.target.value)}>
          <option value="">All Categories</option>
          <option value="conference">Conference</option>
          <option value="workshop">Workshop</option>
          <option value="seminar">Seminar</option>
          <option value="concert">Concert</option>
          <option value="sports">Sports</option>
          <option value="festival">Festival</option>
        </select>
      </div>

      <div className="events-grid">
        {events.length === 0 ? (
          <p>No events found</p>
        ) : (
          events.map(event => (
            <Link to={`/events/${event._id}`} key={event._id} className="event-card">
              <img src={event.imageUrl} alt={event.title} />
              <div className="event-info">
                <h3>{event.title}</h3>
                <p className="event-category">{event.category}</p>
                <p className="event-date">{new Date(event.date).toLocaleDateString()}</p>
                <p className="event-venue">{event.venue}</p>
                <p className="event-price">${event.price}</p>
                <p className="event-seats">{event.availableSeats} seats available</p>
              </div>
            </Link>
          ))
        )}
      </div>
    </div>
  );
}

export default Events;
