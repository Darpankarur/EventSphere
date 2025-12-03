const { SNSClient, PublishCommand } = require('@aws-sdk/client-sns');

const snsClient = new SNSClient({ 
  region: process.env.AWS_REGION || 'us-east-1'
});

const SNS_TOPIC_ARN = process.env.SNS_TOPIC_ARN;

/**
 * Send email notification via SNS
 * SNS will trigger Lambda function which sends email via SES to specific user
 * 
 * @param {string} email - Recipient email address
 * @param {string} subject - Email subject
 * @param {string} message - Email message body
 */
async function sendEmailNotification(email, subject, message) {
  if (!SNS_TOPIC_ARN) {
    console.error('SNS_TOPIC_ARN not configured');
    throw new Error('SNS topic ARN not configured');
  }

  const params = {
    TopicArn: SNS_TOPIC_ARN,
    Subject: subject,
    Message: message,
    MessageAttributes: {
      email: {
        DataType: 'String',
        StringValue: email  // ✅ Lambda will extract this and send to specific user
      }
    }
  };

  try {
    const command = new PublishCommand(params);
    const response = await snsClient.send(command);
    console.log(`SNS message published successfully. MessageId: ${response.MessageId}`);
    console.log(`Email will be sent to: ${email}`);
    return response;
  } catch (error) {
    console.error('Error publishing to SNS:', error);
    throw error;
  }
}

/**
 * Send welcome email to new user
 */
async function sendWelcomeEmail(email, userName) {
  const subject = 'Welcome to EventSphere!';
  const message = `Hello ${userName},

Welcome to EventSphere - Your Gateway to Amazing Events!

We're thrilled to have you join our community. EventSphere makes it easy to discover, book, and manage tickets for exciting events.

Here's what you can do:
• Browse upcoming events across various categories
• Book tickets instantly with our seamless booking system
• Manage your bookings and view your event history
• Get real-time updates about your events

Start exploring events now at https://enpm818rgroup7.work.gd

If you have any questions, feel free to reach out to our support team.

Happy event hunting!

Best regards,
The EventSphere Team

---
This is an automated message. Please do not reply to this email.`;

  return sendEmailNotification(email, subject, message);
}

/**
 * Send booking confirmation email
 */
async function sendBookingConfirmationEmail(email, userName, eventDetails, bookingDetails) {
  const subject = `Booking Confirmed - ${eventDetails.title}`;
  const message = `Hello ${userName},

Your booking has been confirmed!

Event Details:
• Event: ${eventDetails.title}
• Date: ${new Date(eventDetails.date).toLocaleDateString()}
• Time: ${eventDetails.time}
• Venue: ${eventDetails.venue}
• Category: ${eventDetails.category}

Booking Details:
• Booking ID: ${bookingDetails.bookingId}
• Number of Tickets: ${bookingDetails.quantity}
• Total Amount: $${bookingDetails.totalAmount}
• Booking Date: ${new Date(bookingDetails.bookingDate).toLocaleString()}

Important Information:
• Please arrive at least 15 minutes before the event starts
• Bring a valid ID for verification
• Your booking reference: ${bookingDetails.bookingId}

View your booking details at: https://enpm818rgroup7.work.gd/my-bookings

We look forward to seeing you at the event!

Best regards,
The EventSphere Team

---
This is an automated message. Please do not reply to this email.`;

  return sendEmailNotification(email, subject, message);
}

module.exports = {
  sendEmailNotification,
  sendWelcomeEmail,
  sendBookingConfirmationEmail
};
