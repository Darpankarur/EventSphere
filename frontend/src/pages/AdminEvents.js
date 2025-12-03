import React, { useState, useEffect } from 'react';
import axios from 'axios';
import API_CONFIG from '../config/api';
import './AdminEvents.css';

function AdminEvents() {
  const [events, setEvents] = useState([]);
  const [showForm, setShowForm] = useState(false);
  const [formData, setFormData] = useState({
    title: '',
    description: '',
    category: 'conference',
    venue: '',
    date: '',
    time: '',
    capacity: '',
    price: '',
    organizer: '',
    imageUrl: ''
  });

  useEffect(() => {
    fetchEvents();
  }, []);

  const fetchEvents = async () => {
    try {
      const response = await axios.get(`${API_CONFIG.event}/events`);
      setEvents(response.data.events);
    } catch (err) {
      console.error('Error fetching events:', err);
    }
  };

  const handleSubmit = async (e) => {
    e.preventDefault();
    try {
      const token = localStorage.getItem('token');
      await axios.post(
        `${API_CONFIG.event}/events`,
        formData,
        { headers: { Authorization: `Bearer ${token}` } }
      );
      alert('Event created successfully!');
      setShowForm(false);
      fetchEvents();
      setFormData({
        title: '',
        description: '',
        category: 'conference',
        venue: '',
        date: '',
        time: '',
        capacity: '',
        price: '',
        organizer: '',
        imageUrl: ''
      });
    } catch (err) {
      alert(err.response?.data?.error || 'Failed to create event');
    }
  };

  const handleDelete = async (id) => {
    if (!window.confirm('Are you sure?')) return;
    
    try {
      const token = localStorage.getItem('token');
      await axios.delete(`${API_CONFIG.event}/events/${id}`, {
        headers: { Authorization: `Bearer ${token}` }
      });
      alert('Event deleted!');
      fetchEvents();
    } catch (err) {
      alert('Failed to delete event');
    }
  };

  return (
    <div className="admin-events">
      <div className="admin-header">
        <h1>Manage Events</h1>
        <button onClick={() => setShowForm(!showForm)} className="btn btn-primary">
          {showForm ? 'Cancel' : 'Create Event'}
        </button>
      </div>

      {showForm && (
        <form onSubmit={handleSubmit} className="event-form">
          <input
            type="text"
            placeholder="Event Title"
            value={formData.title}
            onChange={(e) => setFormData({...formData, title: e.target.value})}
            required
          />
          <textarea
            placeholder="Description"
            value={formData.description}
            onChange={(e) => setFormData({...formData, description: e.target.value})}
            required
          />
          <select
            value={formData.category}
            onChange={(e) => setFormData({...formData, category: e.target.value})}
          >
            <option value="conference">Conference</option>
            <option value="workshop">Workshop</option>
            <option value="seminar">Seminar</option>
            <option value="concert">Concert</option>
            <option value="sports">Sports</option>
            <option value="festival">Festival</option>
          </select>
          <input
            type="text"
            placeholder="Venue"
            value={formData.venue}
            onChange={(e) => setFormData({...formData, venue: e.target.value})}
            required
          />
          <input
            type="date"
            value={formData.date}
            onChange={(e) => setFormData({...formData, date: e.target.value})}
            required
          />
          <input
            type="text"
            placeholder="Time (e.g., 9:00 AM - 5:00 PM)"
            value={formData.time}
            onChange={(e) => setFormData({...formData, time: e.target.value})}
            required
          />
          <input
            type="number"
            placeholder="Capacity"
            value={formData.capacity}
            onChange={(e) => setFormData({...formData, capacity: e.target.value})}
            required
          />
          <input
            type="number"
            placeholder="Price"
            value={formData.price}
            onChange={(e) => setFormData({...formData, price: e.target.value})}
            required
          />
          <input
            type="text"
            placeholder="Organizer"
            value={formData.organizer}
            onChange={(e) => setFormData({...formData, organizer: e.target.value})}
            required
          />
          <input
            type="url"
            placeholder="Image URL (optional)"
            value={formData.imageUrl}
            onChange={(e) => setFormData({...formData, imageUrl: e.target.value})}
          />
          <small style={{color: '#666', marginTop: '-5px', display: 'block'}}>
            Example: https://images.unsplash.com/photo-1540575467063-178a50c2df87
          </small>
          <button type="submit" className="btn btn-success">Create Event</button>
        </form>
      )}

      <div className="events-table">
        <table>
          <thead>
            <tr>
              <th>Title</th>
              <th>Date</th>
              <th>Venue</th>
              <th>Capacity</th>
              <th>Available</th>
              <th>Price</th>
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            {events.map(event => (
              <tr key={event._id}>
                <td>{event.title}</td>
                <td>{new Date(event.date).toLocaleDateString()}</td>
                <td>{event.venue}</td>
                <td>{event.capacity}</td>
                <td>{event.availableSeats}</td>
                <td>${event.price}</td>
                <td>
                  <button 
                    onClick={() => handleDelete(event._id)}
                    className="btn btn-danger btn-sm"
                  >
                    Delete
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

export default AdminEvents;
